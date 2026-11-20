import SwiftUI

@MainActor
final class PreviewModel: ObservableObject {
    private struct ClipRuntime {
        let url: URL
        let index: FrameIndex
        let name: String
        let containerStart: Double
        let previewW: Int
        let previewH: Int
        let filter: String?
        var decoder: FrameStreamDecoder?
    }

    private weak var document: ProjectDocument?

    @Published var image: NSImage?
    @Published var currentFrame = 0
    @Published var frameCount = 0
    @Published var isLoading = true
    @Published var isPlaying = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var currentClipName: String?
    @Published var joinFrames: [Int] = []

    private(set) var fps: Double = 25

    private var timeline: PreviewTimeline?
    private var runtimes: [UUID: ClipRuntime] = [:]
    private var keyframeAnchors: [Int] = []

    @Published var monitoredTrack = 0
    private var audioPlan: PreviewAudioPlan?
    private var audioPlayer: AudioStreamPlayer?
    private var audioClockBase: Double = 0
    private var audioSegment: Int?
    private var audioFallback = false
    private var audioPrimeDeadline = Date.distantPast

    var outputTracks: [AudioCodecPolicy.OutputAudioTrack] { audioPlan?.tracks ?? [] }

    func trackName(_ t: Int) -> String { audioPlan?.trackName(t) ?? "Track \(t + 1)" }

    private var pendingFrame: Int?
    private var pendingIsJump = false
    private var decodeTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?

    private var cache: [Int: NSImage] = [:]
    private var cacheOrder: [Int] = []
    private let cacheCap = 48

    init(document: ProjectDocument) {
        self.document = document
    }

    var lastFrame: Int { max(0, frameCount - 1) }

    var totalDuration: Double { fps > 0 ? Double(frameCount) / fps : 0 }

    func load() async {
        guard let document else { return }
        let clips = document.project.clips
        guard !clips.isEmpty else {
            statusMessage = "Add clips in Source to preview the assembled output."
            isLoading = false
            return
        }
        guard clips.contains(where: { $0.video != nil }) else {
            statusMessage = "No clip has video to preview yet."
            isLoading = false
            return
        }

        let target = document.project.targetClip ?? clips.first { $0.video != nil }
        guard let targetVideo = target?.video, let target else {
            statusMessage = "No clip has video to preview yet."
            isLoading = false
            return
        }

        do {
            let (canvasW, canvasH) = CutEditorModel.previewSize(for: targetVideo)
            var specs: [PreviewTimeline.ClipSpec] = []
            var clipAudio: [UUID: PreviewAudioPlan.ClipAudio] = [:]
            for clip in clips {
                guard let video = clip.video else { continue }
                guard let url = document.url(for: clip) else {
                    throw FFError.indexFailed("Source file not found for “\(clip.displayName)”.")
                }
                let index = try await document.frameIndex(for: clip)
                let containerStart = await document.containerStart(for: clip)
                let conformed = !MatchEvaluator.matches(clip, target: target)
                specs.append(PreviewTimeline.ClipSpec(
                    clipID: clip.id, pts: index.pts,
                    inPoint: clip.inPoint, outPoint: clip.outPoint,
                    duration: clip.duration, conformed: conformed
                ))
                runtimes[clip.id] = ClipRuntime(
                    url: url, index: index, name: clip.displayName,
                    containerStart: containerStart,
                    previewW: canvasW, previewH: canvasH,
                    filter: conformed
                        ? PreviewFilter.spatialConformChain(
                            source: video, target: targetVideo,
                            canvasW: canvasW, canvasH: canvasH)
                        : nil,
                    decoder: nil
                )
                clipAudio[clip.id] = PreviewAudioPlan.ClipAudio(
                    url: url,
                    containerStart: containerStart,
                    sources: try AudioSourceResolver.resolveSources(
                        for: clip, missingExternal: .degradeToSilence),
                    mixFilters: AudioSourceResolver.resolveMixFilters(for: clip)
                )
            }
            let built = PreviewTimeline.build(clips: specs, targetFrameRate: targetVideo.frameRate)
            timeline = built
            fps = built.targetFps
            frameCount = built.totalFrames
            joinFrames = built.joinFrames
            let tracks = AudioSourceResolver.resolveOutputTracks(
                target: document.project.targetClip, clips: clips)
            audioPlan = PreviewAudioPlan.build(
                segments: built.segments, targetFps: built.targetFps,
                clips: clipAudio, tracks: tracks)
            monitoredTrack = min(max(0, document.project.monitoredOutputTrack ?? 0),
                                 max(0, tracks.count - 1))
            keyframeAnchors = built.keyframeAnchorFrames { [runtimes] id in
                runtimes[id]?.index
            }
            isLoading = false
            seek(to: 0)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }

    func seek(to frame: Int) {
        guard frameCount > 0 else { return }
        if isPlaying { stopPlayback() }
        let previous = currentFrame
        let clamped = min(max(0, frame), lastFrame)
        currentFrame = clamped
        updateClipName(for: clamped)

        if let cached = cache[clamped] {
            image = cached
            pendingFrame = nil
            return
        }
        pendingFrame = clamped
        pendingIsJump = abs(clamped - previous) > cacheCap
        startDecodeWorker()
    }

    func step(by delta: Int) { seek(to: currentFrame + delta) }
    func goToStart() { seek(to: 0) }
    func goToEnd() { seek(to: lastFrame) }

    var canSaveFrame: Bool { image != nil && timeline != nil }

    func frameSnapshotRequest() -> FrameSnapshotRequest? {
        guard let timeline, image != nil,
              let (segmentIndex, local) = timeline.locate(currentFrame) else { return nil }
        let segment = timeline.segments[segmentIndex]
        guard let runtime = runtimes[segment.clipID],
              let clip = document?.project.clips.first(where: { $0.id == segment.clipID }),
              let video = clip.video, video.width > 0, video.height > 0 else { return nil }
        let source = timeline.sourceFrame(in: segment, local: local, pts: runtime.index.pts)
        let deinterlaces = runtime.filter?.hasPrefix("bwdif") ?? false
        let filter = deinterlaces ? "bwdif=mode=0,scale=\(video.width):\(video.height)" : nil
        let url = runtime.url
        let index = runtime.index
        let start = runtime.containerStart
        let (w, h) = (video.width, video.height)
        return FrameSnapshotRequest(
            suggestedName: FrameSnapshot.fileName(
                clipName: clip.displayName, timecode: timecode(forFrame: currentFrame)),
            defaultDirectory: url.deletingLastPathComponent()
        ) {
            try? await FrameExtractor.imageData(
                url: url, index: index, frame: source,
                width: w, height: h, containerStart: start, filter: filter)
        }
    }

    func stepToPreviousKeyframe() {
        if let previous = keyframeAnchors.last(where: { $0 < currentFrame }) {
            seek(to: previous)
        }
    }

    func stepToNextKeyframe() {
        if let next = keyframeAnchors.first(where: { $0 > currentFrame }) {
            seek(to: next)
        }
    }

    private func updateClipName(for frame: Int) {
        guard let timeline, let (i, _) = timeline.locate(frame) else { return }
        let name = runtimes[timeline.segments[i].clipID]?.name
        if currentClipName != name { currentClipName = name }
    }

    private func startDecodeWorker() {
        guard decodeTask == nil else { return }
        decodeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.decodeTask = nil }
            while let target = self.pendingFrame {
                if let cached = self.cache[target] {
                    if self.currentFrame == target { self.image = cached }
                    if self.pendingFrame == target { self.pendingFrame = nil }
                    continue
                }
                let produced = await self.produce(target, maskJumpWithKeyframe: self.pendingIsJump)
                if let produced, self.currentFrame == target { self.image = produced }
                if self.pendingFrame == target { self.pendingFrame = nil }
            }
        }
    }

    private func produce(_ target: Int, maskJumpWithKeyframe jump: Bool = false) async -> NSImage? {
        guard let timeline, let (segmentIndex, local) = timeline.locate(target) else { return nil }
        let segment = timeline.segments[segmentIndex]
        guard var runtime = runtimes[segment.clipID] else { return nil }
        let source = timeline.sourceFrame(in: segment, local: local, pts: runtime.index.pts)

        if runtime.decoder == nil {
            runtime.decoder = FrameStreamDecoder(
                url: runtime.url, index: runtime.index,
                containerStart: runtime.containerStart,
                width: runtime.previewW, height: runtime.previewH,
                useHardware: true, filter: runtime.filter, windowSize: cacheCap
            )
            runtimes[segment.clipID] = runtime
        }
        guard let decoder = runtime.decoder else { return nil }

        if jump, let preview = await decoder.keyframePreview(forFrameAt: source) {
            cacheDecoded(frame: preview.frame, image: preview.image,
                         segment: segment, requested: (target, source))
            if currentFrame == target { image = preview.image }
            if pendingFrame != target { return nil }
        }

        let result = await decoder.image(at: source)
        for entry in result.window {
            cacheDecoded(frame: entry.frame, image: entry.image,
                         segment: segment, requested: (target, source))
        }
        var produced = result.image
        if produced == nil,
           let data = try? await FrameExtractor.imageData(
               url: runtime.url, index: runtime.index, frame: source,
               width: runtime.previewW, height: runtime.previewH,
               containerStart: runtime.containerStart,
               filter: runtime.filter) {
            produced = NSImage(data: data)
        }
        if let produced { cacheInsert(target, produced) }
        return produced
    }

    func togglePlay() { isPlaying ? stopPlayback() : play() }

    func play() {
        guard !isPlaying, frameCount > 0 else { return }
        decodeTask?.cancel()
        decodeTask = nil
        pendingFrame = nil
        isPlaying = true
        startAudio(atFrame: currentFrame)
        let fallbackFrameDuration = UInt64(1_000_000_000 / max(1.0, fps))
        playTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isPlaying && !Task.isCancelled {
                if self.currentFrame >= self.lastFrame { self.stopPlayback(); break }

                var next = self.currentFrame + 1
                if !self.audioFallback {
                    if let elapsed = self.audioPlayer?.elapsedSeconds {
                        let outputTime = self.audioClockBase + elapsed
                        let target = min(Int(outputTime * self.fps), self.lastFrame)
                        if target <= self.currentFrame {
                            let nextTime = Double(self.currentFrame + 1) / self.fps
                            let wait = nextTime - outputTime
                            try? await Task.sleep(nanoseconds: UInt64(max(0.002, wait) * 1_000_000_000))
                            continue
                        }
                        next = target
                        if let (segment, _) = self.timeline?.locate(next),
                           segment != self.audioSegment {
                            self.startAudio(atFrame: next)
                        }
                    } else if Date() < self.audioPrimeDeadline {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    } else {
                        self.audioFallback = true
                        self.audioPlayer?.stop()
                    }
                }

                self.currentFrame = next
                self.updateClipName(for: next)
                let frame: NSImage?
                if let cached = self.cache[next] {
                    frame = cached
                } else {
                    frame = await self.produce(next)
                }
                if !self.isPlaying || Task.isCancelled { break }
                if let frame { self.image = frame }
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
        audioSegment = nil
    }

    func setMonitoredTrack(_ slot: Int) {
        guard slot != monitoredTrack else { return }
        monitoredTrack = slot
        document?.setMonitoredOutputTrack(slot)
        if isPlaying { startAudio(atFrame: currentFrame) }
    }

    private func startAudio(atFrame frame: Int) {
        let outputTime = Double(frame) / max(1.0, fps)
        guard let plan = audioPlan, !plan.tracks.isEmpty,
              let (segment, _) = timeline?.locate(frame),
              let entry = plan.entry(track: monitoredTrack, segment: segment,
                                     atOutputTime: outputTime) else {
            audioFallback = true
            audioPlayer?.stop()
            return
        }
        let player = audioPlayer ?? AudioStreamPlayer()
        audioPlayer = player
        audioClockBase = outputTime
        audioSegment = segment
        audioFallback = false
        audioPrimeDeadline = Date().addingTimeInterval(0.3)
        switch entry.source {
        case .stream(let url, let streamIndex):
            player.start(url: url, streamIndex: streamIndex, seekSeconds: entry.seekSeconds,
                         filter: plan.legFilter(track: monitoredTrack, segment: segment),
                         duration: entry.remaining)
        case .silence:
            player.startSilence(duration: entry.remaining)
        }
    }

    private func cacheDecoded(frame: Int, image: NSImage, segment: PreviewTimeline.Segment,
                              requested: (output: Int, source: Int)) {
        if segment.conformed {
            if frame == requested.source { cacheInsert(requested.output, image) }
            return
        }
        let output = segment.outputStart + (frame - segment.keptStart)
        guard output >= segment.outputStart,
              output < segment.outputStart + segment.outputCount else { return }
        cacheInsert(output, image)
    }

    private func cacheInsert(_ frame: Int, _ image: NSImage) {
        if cache[frame] == nil { cacheOrder.append(frame) }
        cache[frame] = image
        while cacheOrder.count > cacheCap {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    func teardown() {
        stopPlayback()
        decodeTask?.cancel()
        decodeTask = nil
        pendingFrame = nil
        for id in runtimes.keys {
            runtimes[id]?.decoder?.stop()
            runtimes[id]?.decoder = nil
        }
        audioPlayer?.stop()
        audioPlayer = nil
        cache.removeAll()
        cacheOrder.removeAll()
    }

    func timecode(forFrame frame: Int) -> String {
        guard fps > 0 else { return "--:--:--:--" }
        let fpsInt = max(1, Int(fps.rounded()))
        let totalSeconds = frame / fpsInt
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        let f = frame % fpsInt
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }
}
