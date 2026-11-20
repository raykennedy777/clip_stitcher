import SwiftUI

@MainActor
final class CutEditorModel: ObservableObject {
    let clip: Clip
    let url: URL
    let fps: Double
    private weak var document: ProjectDocument?

    @Published var image: NSImage?
    @Published var currentFrame: Int = 0
    @Published var frameCount: Int = 0
    @Published var inPoint: Int?
    @Published var outPoint: Int?
    @Published var splitPoints: Set<Int> = []
    @Published var isIndexing = true
    @Published var isPlaying = false
    @Published var isSceneScanning = false
    @Published var errorMessage: String?
    @Published var isShowingJump = false

    var onClose: (() -> Void)?

    private var index: FrameIndex?
    private var leadingCounts: [Int?] = []
    private var decoder: FrameStreamDecoder?
    private var playTask: Task<Void, Never>?
    private var sceneScanTask: Task<Void, Never>?

    private var audioPlayer: AudioStreamPlayer?
    private var audioClockBase: Double = 0
    private var audioFallback = false
    private var audioPrimeDeadline = Date.distantPast
    private var containerStartTime: Double = 0
    private var playbackOrigin = 0

    private var previewW = 0
    private var previewH = 0

    private var pendingFrame: Int?
    private var pendingIsJump = false
    private var decodeTask: Task<Void, Never>?

    private var cache: [Int: NSImage] = [:]
    private var cacheOrder: [Int] = []
    private let cacheCap = 48

    private var keyframeCache = BoundedLRU<NSImage>(capacity: 16)
    private var prefetcher: KeyframePrefetcher?
    private var keyframes: [Int] = []
    private var lastPrefetchAnchor = -1

    init(clip: Clip, url: URL, document: ProjectDocument) {
        self.clip = clip
        self.url = url
        self.document = document
        self.inPoint = clip.inPoint
        self.outPoint = clip.outPoint
        self.fps = Self.parseFrameRate(clip.video?.frameRate)
    }

    var lastFrame: Int { max(0, frameCount - 1) }

    var canStep: Bool { frameCount > 0 && !isIndexing }

    var canScene: Bool { canStep && !isSceneScanning }

    func load() async {
        do {
            let built: FrameIndex
            if let document {
                built = try await document.frameIndex(for: clip)
            } else {
                built = try await FrameIndexer.buildIndex(url: url)
            }
            index = built
            frameCount = built.count
            let (w, h) = Self.previewSize(for: clip.video)
            previewW = w
            previewH = h
            containerStartTime = await MediaProbe.containerStartTime(url: url)
            decoder = FrameStreamDecoder(
                url: url, index: built, containerStart: containerStartTime,
                width: w, height: h, useHardware: true, windowSize: cacheCap
            )
            keyframes = built.keyframeFlags.enumerated().filter(\.element).map(\.offset)
            leadingCounts = CopySafeBoundaryDetector.leadingPictureCounts(
                keyframeFlags: built.keyframeFlags, dts: built.dts)
            prefetcher = KeyframePrefetcher(
                url: url, index: built, containerStart: containerStartTime,
                width: w, height: h
            )
            isIndexing = false
            seek(to: document?.lastViewedFrame(for: clip.id) ?? inPoint ?? 0)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isIndexing = false
        }
    }

    #if DEBUG
    func primeForTesting(frameCount: Int, leadingCounts: [Int?]) {
        let built = FrameIndex(
            pts: (0..<frameCount).map { Double($0) / 25 },
            keyframeFlags: Array(repeating: false, count: frameCount))
        index = built
        self.frameCount = built.count
        self.leadingCounts = leadingCounts
        isIndexing = false
    }
    #endif

    func seek(to frame: Int) {
        guard let index else { return }
        if isPlaying { stopPlayback() }
        let previous = currentFrame
        let clamped = min(max(0, frame), max(0, index.count - 1))
        currentFrame = clamped

        prefetchNeighborhood(around: clamped)

        if let cached = cache[clamped] {
            image = cached
            pendingFrame = nil
            return
        }

        let warmed = keyframeCache.value(at: clamped)
        if let warmed {
            image = warmed
        }

        pendingFrame = clamped
        pendingIsJump = warmed == nil && abs(clamped - previous) > cacheCap
        startDecodeWorker()
    }

    private func prefetchNeighborhood(around frame: Int) {
        guard !isPlaying, let index, let prefetcher, !keyframes.isEmpty else { return }
        guard let anchor = index.keyframeIndex(atOrBefore: frame),
              anchor != lastPrefetchAnchor,
              let position = keyframes.firstIndex(of: anchor) else { return }
        lastPrefetchAnchor = anchor
        let wanted = KeyframePrefetcher
            .neighborhood(position: position, keyframes: keyframes, cap: keyframeCache.capacity)
            .filter { !keyframeCache.contains($0) }
        guard !wanted.isEmpty else { return }
        prefetcher.fetch(wanted) { [weak self] frame, image in
            Task { @MainActor in
                guard let self else { return }
                self.keyframeCache.insert(image, at: frame)
                if self.currentFrame == frame, self.pendingFrame == frame {
                    self.image = image
                }
            }
        }
    }

    private func startDecodeWorker() {
        guard decodeTask == nil else { return }
        decodeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.decodeTask = nil }
            while let target = self.pendingFrame, let decoder = self.decoder, let index = self.index {
                let jump = self.pendingIsJump

                if let cached = self.cache[target] {
                    if self.currentFrame == target { self.image = cached }
                    if self.pendingFrame == target { self.pendingFrame = nil }
                    continue
                }

                if jump, let preview = await decoder.keyframePreview(forFrameAt: target) {
                    self.cacheInsert(preview.frame, preview.image)
                    if self.currentFrame == target { self.image = preview.image }
                    if self.pendingFrame != target { continue }
                }

                let result = await decoder.image(at: target)
                for entry in result.window { self.cacheInsert(entry.frame, entry.image) }
                var produced = result.image
                if produced == nil,
                   let data = try? await FrameExtractor.imageData(
                       url: self.url, index: index, frame: target,
                       width: self.previewW, height: self.previewH,
                       containerStart: self.containerStartTime) {
                    produced = NSImage(data: data)
                }
                if let produced {
                    self.cacheInsert(target, produced)
                    if self.currentFrame == target { self.image = produced }
                }
                if self.pendingFrame == target { self.pendingFrame = nil }
            }
        }
    }

    func step(by delta: Int) { seek(to: currentFrame + delta) }
    func goToStart() { seek(to: 0) }
    func goToEnd() { seek(to: lastFrame) }

    var canSaveFrame: Bool { image != nil && index != nil }

    func frameSnapshotRequest() -> FrameSnapshotRequest? {
        guard let index, image != nil,
              let video = clip.video, video.width > 0, video.height > 0 else { return nil }
        let url = self.url
        let frame = currentFrame
        let start = containerStartTime
        let (w, h) = (video.width, video.height)
        return FrameSnapshotRequest(
            suggestedName: FrameSnapshot.fileName(
                clipName: clip.displayName, timecode: timecode(forFrame: frame)),
            defaultDirectory: url.deletingLastPathComponent()
        ) {
            try? await FrameExtractor.imageData(
                url: url, index: index, frame: frame,
                width: w, height: h, containerStart: start)
        }
    }

    func stepToPreviousKeyframe() {
        guard let index, currentFrame > 0 else { return }
        seek(to: index.keyframeIndex(atOrBefore: currentFrame - 1) ?? 0)
    }

    func stepToNextKeyframe() {
        guard let index, let next = index.keyframeIndex(after: currentFrame) else { return }
        seek(to: next)
    }

    func scanToSceneChange(forward: Bool) {
        guard !isSceneScanning, let index, frameCount > 0 else { return }
        let current = currentFrame
        let windowFrames = Int((SceneScan.windowSeconds * fps).rounded())
        let limit = forward
            ? min(current + windowFrames, lastFrame)
            : max(current - windowFrames, 0)
        guard limit != current else { return }

        let pts = index.pts
        let startTime = pts.first ?? 0
        let windowStart = pts[min(current, limit)]
        let seekStart = max(0, windowStart - startTime - SceneScan.guardSeconds)
        let duration = (windowStart - startTime - seekStart) + SceneScan.windowSeconds + 0.3
        let deinterlace = ConformEngine.isInterlaced(clip.video?.fieldOrder)

        isSceneScanning = true
        sceneScanTask = Task { @MainActor [weak self, url] in
            let frames = await SceneScan.sceneFrames(
                url: url, seekStart: seekStart, duration: duration,
                deinterlace: deinterlace, pts: pts)
            guard let self, !Task.isCancelled else { return }
            self.isSceneScanning = false
            let landing = forward
                ? SceneScan.forwardLanding(sceneFrames: frames, current: current, cap: limit)
                : SceneScan.backwardLanding(sceneFrames: frames, current: current, floor: limit)
            self.seek(to: landing)
        }
    }

    private func cacheInsert(_ frame: Int, _ image: NSImage) {
        if cache[frame] == nil { cacheOrder.append(frame) }
        cache[frame] = image
        while cacheOrder.count > cacheCap {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private var snapsCutPoints: Bool {
        let live = document?.project.clips.first { $0.id == clip.id } ?? clip
        return FieldCodedSupport.requiresCopyOnlyCuts(fieldCoded: live.fieldCoded, codec: live.video?.codec)
    }

    private func markTarget(_ snap: (Int, [Int?]) -> Int?) -> Int? {
        snapsCutPoints ? snap(currentFrame, leadingCounts) : currentFrame
    }

    func setIn() {
        guard let target = markTarget(CopyCutSnapper.snapInPoint) else { return }
        inPoint = target
        if let out = outPoint, out < target { outPoint = nil }
        if target != currentFrame { seek(to: target) }
    }

    func setOut() {
        guard let target = markTarget(CopyCutSnapper.snapOutPoint) else { return }
        outPoint = snapsCutPoints && target == lastFrame ? nil : target
        if let start = inPoint, start > target { inPoint = nil }
        if target != currentFrame { seek(to: target) }
    }

    var canToggleSplit: Bool {
        frameCount > 0 && SplitRanges.isLive(
            currentFrame, inPoint: inPoint, outPoint: outPoint, lastFrame: lastFrame)
    }

    var isSplitAtPlayhead: Bool { splitPoints.contains(currentFrame) }

    var liveSplitPoints: [Int] {
        SplitRanges.liveSplits(splitPoints, inPoint: inPoint, outPoint: outPoint, lastFrame: lastFrame)
    }

    var inertSplitPoints: [Int] {
        splitPoints.subtracting(liveSplitPoints).sorted()
    }

    func toggleSplit() {
        guard canToggleSplit else { return }
        guard let target = markTarget(CopyCutSnapper.snapInPoint) else { return }
        if splitPoints.contains(target) {
            splitPoints.remove(target)
        } else {
            splitPoints.insert(target)
        }
        if target != currentFrame { seek(to: target) }
    }

    func confirm() {
        let ranges = SplitRanges.ranges(
            splits: splitPoints, inPoint: inPoint, outPoint: outPoint, lastFrame: lastFrame)
        if ranges.count > 1 {
            document?.splitClip(id: clip.id, ranges: ranges)
        } else {
            document?.setInOut(id: clip.id, inPoint: inPoint, outPoint: outPoint)
        }
        teardown()
        onClose?()
    }

    func cancel() {
        teardown()
        onClose?()
    }

    func togglePlay() { isPlaying ? stopPlayback() : play() }

    func play() {
        guard let index, let decoder, !isPlaying, frameCount > 0 else { return }
        decodeTask?.cancel()
        decodeTask = nil
        pendingFrame = nil
        isPlaying = true
        playbackOrigin = currentFrame
        startAudio(atFrame: currentFrame)
        let fallbackFrameDuration = UInt64(1_000_000_000 / max(1.0, fps))
        playTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isPlaying && !Task.isCancelled {
                let end = Self.playbackEnd(
                    outPoint: self.outPoint, origin: self.playbackOrigin,
                    lastFrame: index.count - 1)
                if self.currentFrame >= end { self.stopPlayback(); break }

                var next = self.currentFrame + 1
                if !self.audioFallback {
                    if let elapsed = self.audioPlayer?.elapsedSeconds {
                        let target = index.frameIndex(atOrBeforeTime: self.audioClockBase + elapsed)
                        if target <= self.currentFrame {
                            let nextPts = index.pts[min(self.currentFrame + 1, end)]
                            let wait = (nextPts - self.audioClockBase) - elapsed
                            try? await Task.sleep(nanoseconds: UInt64(max(0.002, wait) * 1_000_000_000))
                            continue
                        }
                        next = min(target, end)
                    } else if Date() < self.audioPrimeDeadline {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    } else {
                        self.audioFallback = true
                        self.audioPlayer?.stop()
                    }
                }

                self.currentFrame = next
                let frame: NSImage?
                if let cached = self.cache[next] {
                    frame = cached
                } else {
                    let result = await decoder.image(at: next)
                    for entry in result.window { self.cacheInsert(entry.frame, entry.image) }
                    frame = result.image
                }
                if !self.isPlaying || Task.isCancelled { break }
                if let frame {
                    self.image = frame
                    self.cacheInsert(next, frame)
                }
                if self.audioFallback {
                    try? await Task.sleep(nanoseconds: fallbackFrameDuration)
                }
            }
        }
    }

    func stopPlayback() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
        audioPlayer?.stop()
    }

    nonisolated static func playbackEnd(outPoint: Int?, origin: Int, lastFrame: Int) -> Int {
        guard let outPoint, outPoint > origin else { return lastFrame }
        return min(outPoint, lastFrame)
    }

    func monitoredAudioTrackChanged() {
        if isPlaying { startAudio(atFrame: currentFrame) }
    }

    private func startAudio(atFrame frame: Int) {
        guard let index, frame < index.count else { return }
        guard let source = monitoredAudioSource() else {
            audioFallback = true
            audioPlayer?.stop()
            return
        }
        let player = audioPlayer ?? AudioStreamPlayer()
        audioPlayer = player
        audioClockBase = index.pts[frame]
        audioFallback = false
        audioPrimeDeadline = Date().addingTimeInterval(0.3)
        player.start(
            url: source.url, streamIndex: source.streamIndex,
            seekSeconds: AudioStreamPlayer.seekSeconds(
                sourceTime: index.pts[frame], containerStartTime: containerStartTime),
            filter: source.mixFilter)
    }

    private func monitoredAudioSource() -> (url: URL, streamIndex: Int, mixFilter: String?)? {
        let live = document?.project.clips.first { $0.id == clip.id } ?? clip
        let selections = live.resolvedAudioSelections
        guard !selections.isEmpty else { return nil }
        let slot = min(max(0, live.monitoredAudioTrack ?? 0), selections.count - 1)
        let mixFilter = ConformEngine.mixFilter(
            selections[slot].mix, sourceChannels: live.effectiveAudioTracks[slot]?.channels)
        switch selections[slot].selection {
        case .stream(let i):
            guard i < live.allAudioTracks.count else { return nil }
            return (url, i, mixFilter)
        case .external(let bookmark, _, let streamIndex, _, _):
            var stale = false
            guard let extURL = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: extURL.path) else { return nil }
            return (extURL, streamIndex, mixFilter)
        }
    }

    func teardown() {
        if index != nil {
            document?.setLastViewedFrame(currentFrame, for: clip.id)
        }
        stopPlayback()
        decodeTask?.cancel()
        decodeTask = nil
        pendingFrame = nil
        sceneScanTask?.cancel()
        sceneScanTask = nil
        isSceneScanning = false
        decoder?.stop()
        decoder = nil
        prefetcher?.stop()
        prefetcher = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    static func previewSize(for video: VideoProperties?) -> (Int, Int) {
        let storedW = video?.width ?? 1280
        let storedH = video?.height ?? 720
        guard storedW > 0, storedH > 0 else { return (1280, 720) }

        var displayW = Double(storedW)
        var displayH = Double(storedH)
        let (sarN, sarD) = parseAspectRatio(video?.sampleAspectRatio)
        if sarN > 0, sarD > 0, sarN != sarD {
            if sarN > sarD {
                displayW = Double(storedW) * Double(sarN) / Double(sarD)
            } else {
                displayH = Double(storedH) * Double(sarD) / Double(sarN)
            }
        }

        let maxWidth = 1280.0
        if displayW > maxWidth {
            displayH *= maxWidth / displayW
            displayW = maxWidth
        }
        return (even(Int(displayW.rounded())), even(Int(displayH.rounded())))
    }

    private static func even(_ value: Int) -> Int { value - (value % 2) }

    static func parseAspectRatio(_ raw: String?) -> (Int, Int) {
        guard let raw, raw.contains(":") else { return (1, 1) }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), n > 0, d > 0 else {
            return (1, 1)
        }
        return (n, d)
    }

    func timecode(forFrame frame: Int) -> String {
        guard fps > 0 else { return "--:--:--:--" }
        let fpsInt = Int(fps.rounded())
        let totalSeconds = frame / max(1, fpsInt)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        let f = frame % max(1, fpsInt)
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }

    static func parseFrameRate(_ raw: String?) -> Double {
        guard let raw else { return 25 }
        if raw.contains("/") {
            let parts = raw.split(separator: "/")
            if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
                return n / d
            }
            return 25
        }
        return Double(raw) ?? 25
    }
}
