import SwiftUI

/// State and behavior for one clip's cut-editor window: builds the frame index,
/// drives frame-accurate seeking/stepping, best-effort playback, and in/out marking.
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
    @Published var isIndexing = true
    @Published var isPlaying = false
    @Published var isSceneScanning = false
    @Published var errorMessage: String?

    /// Set by the presenter to close this editor's window.
    var onClose: (() -> Void)?

    private var index: FrameIndex?
    private var decoder: FrameStreamDecoder?
    private var playTask: Task<Void, Never>?
    private var sceneScanTask: Task<Void, Never>?

    /// Audio playback of the monitored track (issue #7). While the player runs it
    /// is the master clock: the play loop derives the frame on screen from elapsed
    /// audio time, so decode pacing can't drift into lip-sync error.
    private var audioPlayer: AudioStreamPlayer?
    /// Source presentation time at the audio clock's zero (where playback started
    /// or last seeked); frame on screen = frame at `audioClockBase + elapsed`.
    private var audioClockBase: Double = 0
    /// True when this play session runs without an audio clock — no monitored
    /// source, or the stream never produced samples (e.g. playing from beyond the
    /// audio's end) — and the loop paces by sleep like the pre-audio editor.
    private var audioFallback = false
    /// How long the play loop waits for the first samples before falling back.
    /// Priming measures ~50 ms; a stream with no data at all (EOF right away)
    /// never primes, and playback shouldn't stall forever.
    private var audioPrimeDeadline = Date.distantPast
    /// The container's start_time — input `-ss` is measured from it (ADR-0013
    /// trap), so audio seeks subtract it from the frame's pts.
    private var containerStartTime: Double = 0
    /// The frame this play session started (or last re-based) from, deciding
    /// whether the out point stops it — see `playbackEnd`.
    private var playbackOrigin = 0

    /// Display-corrected preview dimensions (SAR applied), resolved once at load and
    /// reused by the decoder and the fallback extractor so both render alike.
    private var previewW = 0
    private var previewH = 0

    /// The latest frame the user wants displayed that isn't cached yet, and whether
    /// arriving there is a jump (worth an instant keyframe preview). A single decode
    /// worker drains this toward the most recent request, so holding an arrow key
    /// never cancels an in-flight decode — it just retargets the worker.
    private var pendingFrame: Int?
    private var pendingIsJump = false
    private var decodeTask: Task<Void, Never>?

    /// Small cache of recently shown frames (FIFO) so backward stepping over
    /// just-viewed frames is instant. Forward stepping is served directly by the
    /// decoder, which keeps these bounded and modest in memory.
    private var cache: [Int: NSImage] = [:]
    private var cacheOrder: [Int] = []
    private let cacheCap = 48

    init(clip: Clip, url: URL, document: ProjectDocument) {
        self.clip = clip
        self.url = url
        self.document = document
        self.inPoint = clip.inPoint
        self.outPoint = clip.outPoint
        self.fps = Self.parseFrameRate(clip.video?.frameRate)
    }

    var lastFrame: Int { max(0, frameCount - 1) }

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
            decoder = FrameStreamDecoder(
                url: url, index: built, width: w, height: h,
                useHardware: true, windowSize: cacheCap
            )
            containerStartTime = await MediaProbe.containerStartTime(url: url)
            isIndexing = false
            // Resume where this clip's editor was last closed; a never-opened clip
            // starts at its in point (frame 0 when none is set).
            seek(to: document?.lastViewedFrame(for: clip.id) ?? inPoint ?? 0)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isIndexing = false
        }
    }

    // MARK: - Navigation

    func seek(to frame: Int) {
        guard let index else { return }
        let previous = currentFrame
        let clamped = min(max(0, frame), max(0, index.count - 1))
        currentFrame = clamped

        // A seek during playback moves the audio with it: restart the stream at
        // the new playhead (the play loop re-derives frames from the new base)
        // and re-base the session, so scrubbing past the out point mid-play
        // continues to the clip end instead of stopping on the next tick.
        if isPlaying {
            playbackOrigin = clamped
            startAudio(atFrame: clamped)
        }

        // Instant path: a recently-decoded frame (e.g. stepping back over the cache).
        if let cached = cache[clamped] {
            image = cached
            pendingFrame = nil
            return
        }

        // Otherwise hand the frame to the decode worker. A move beyond a contiguous
        // run is a "jump" worth an instant keyframe preview; ±1 steps are not (a
        // keyframe flash there would be jarring).
        pendingFrame = clamped
        pendingIsJump = abs(clamped - previous) > cacheCap
        startDecodeWorker()
    }

    /// Drives the decoder toward `pendingFrame`, retargeting whenever the user moves
    /// again, until the cache (or a decode) satisfies the latest request. Only one
    /// worker runs at a time; subsequent seeks just update `pendingFrame`.
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

                // Show the GOP keyframe immediately on a jump to mask the warm-up.
                if jump, let preview = await decoder.keyframePreview(forFrameAt: target) {
                    self.cacheInsert(preview.frame, preview.image)
                    if self.currentFrame == target { self.image = preview.image }
                    if self.pendingFrame != target { continue } // user moved on
                }

                let result = await decoder.image(at: target)
                for entry in result.window { self.cacheInsert(entry.frame, entry.image) }
                var produced = result.image
                if produced == nil,
                   let data = try? await FrameExtractor.imageData(
                       url: self.url, index: index, frame: target,
                       width: self.previewW, height: self.previewH) {
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

    /// Jump to the nearest keyframe before the current frame. Landing on a keyframe
    /// is the decoder's cheapest seek, so these jumps feel instant.
    func stepToPreviousKeyframe() {
        guard let index, currentFrame > 0 else { return }
        seek(to: index.keyframeIndex(atOrBefore: currentFrame - 1))
    }

    /// Jump to the nearest keyframe after the current frame (stays put past the
    /// last keyframe).
    func stepToNextKeyframe() {
        guard let index, let next = index.keyframeIndex(after: currentFrame) else { return }
        seek(to: next)
    }

    /// Jump to the next/previous scene change: scan up to 5 seconds from the
    /// playhead for a frame whose difference from its predecessor crosses the
    /// scene threshold, and land there — or at the 5-second cap when the window
    /// holds no cut, so the key always moves the playhead. Like seek(), this
    /// doesn't stop playback.
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
        // The scan decodes from a guard before the window start (the current frame
        // going forward, the floor going backward) so every window frame has a
        // predecessor to diff against.
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

    // MARK: - In / out points

    func setIn() {
        inPoint = currentFrame
        if let out = outPoint, out < currentFrame { outPoint = nil }
    }

    func setOut() {
        outPoint = currentFrame
        if let start = inPoint, start > currentFrame { inPoint = nil }
    }

    /// OK: write the selection back to the document, then close.
    func confirm() {
        document?.setInOut(id: clip.id, inPoint: inPoint, outPoint: outPoint)
        teardown()
        onClose?()
    }

    /// Cancel: close without writing the selection back.
    func cancel() {
        teardown()
        onClose?()
    }

    // MARK: - Playback (audio-clocked when a monitored track plays — issue #7;
    // silent open-loop pacing otherwise, as shipped under ADR-0003)

    func togglePlay() { isPlaying ? stopPlayback() : play() }

    func play() {
        guard let index, let decoder, !isPlaying, frameCount > 0 else { return }
        // Playback owns the decoder while running; stand the seek worker down.
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

                // Pick the next frame to show. With an audio clock running, it is
                // whatever frame the audio has reached — ahead of +1 when decode
                // lagged (frames are skipped to hold sync), or not yet due (sleep
                // until the next frame's presentation time).
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
                        // Audio spawned but hasn't produced its first samples yet.
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    } else {
                        // No samples in time (e.g. playing from beyond the audio's
                        // end) — this session paces by sleep instead of stalling.
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

    /// Where a play session stops: the out point when the session began before
    /// it (playback "previews the selection"), else the clip's last frame — so
    /// pressing Play with the playhead at or past the out point plays the rest
    /// of the clip instead of stopping on the first tick (a dead-feeling button;
    /// QA finding on issue #7's verification pass). Recomputed every tick because
    /// the out point can be re-marked mid-play.
    nonisolated static func playbackEnd(outPoint: Int?, origin: Int, lastFrame: Int) -> Int {
        guard let outPoint, outPoint > origin else { return lastFrame }
        return min(outPoint, lastFrame)
    }

    /// Called when the Audio dropdown changes: a switch mid-play restarts the
    /// stream on the newly monitored source at the playhead.
    func monitoredAudioTrackChanged() {
        if isPlaying { startAudio(atFrame: currentFrame) }
    }

    /// Starts (or restarts) the monitored track's audio at `frame`, making the
    /// audio the playback clock. With no playable source the session is marked
    /// for sleep-paced fallback instead.
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
                sourceTime: index.pts[frame], containerStartTime: containerStartTime))
    }

    /// The monitored audio slot resolved to a playable source: the clip's own file
    /// and stream, or an external file's chosen stream (aligned file start =
    /// video-file start, ADR-0014 — the same seek offset applies). Reads the live
    /// clip — the dropdown and settings sheet write to the document, and this
    /// model's `clip` is a snapshot from when the window opened. nil when there is
    /// nothing playable: no slots, a slot past the clip's own streams (silence),
    /// or an external bookmark that no longer resolves.
    private func monitoredAudioSource() -> (url: URL, streamIndex: Int)? {
        let live = document?.project.clips.first { $0.id == clip.id } ?? clip
        let selections = live.resolvedAudioSelections
        guard !selections.isEmpty else { return nil }
        let slot = min(max(0, live.monitoredAudioTrack ?? 0), selections.count - 1)
        switch selections[slot] {
        case .stream(let i):
            guard i < live.allAudioTracks.count else { return nil }
            return (url, i)
        case .external(let bookmark, _, let streamIndex, _, _):
            var stale = false
            guard let extURL = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: extURL.path) else { return nil }
            return (extURL, streamIndex)
        }
    }

    /// Stop playback and tear down the decoder process. Called on OK/Cancel and on
    /// window close so no ffmpeg process is left running.
    func teardown() {
        // Remember the closing position so reopening resumes here. Skipped when the
        // clip never loaded — a failed open shouldn't reset a good saved position.
        if index != nil {
            document?.setLastViewedFrame(currentFrame, for: clip.id)
        }
        stopPlayback()
        decodeTask?.cancel()
        decodeTask = nil
        pendingFrame = nil
        sceneScanTask?.cancel() // ProcessRunner kills the scan's ffmpeg on cancel
        sceneScanTask = nil
        isSceneScanning = false
        decoder?.stop()
        decoder = nil
        audioPlayer?.stop() // kills the audio ffmpeg process (same no-orphans rule)
        audioPlayer = nil
    }

    // MARK: - Helpers

    /// Preview decode size: the clip's **display** dimensions (pixel aspect ratio
    /// applied), capped at 1280 wide and kept even. Applying SAR means anamorphic
    /// content — e.g. PAL 720×576 with SAR 64:45 — previews at its true 1024×576
    /// (16:9) shape instead of squished into storage dimensions.
    static func previewSize(for video: VideoProperties?) -> (Int, Int) {
        let storedW = video?.width ?? 1280
        let storedH = video?.height ?? 720
        guard storedW > 0, storedH > 0 else { return (1280, 720) }

        var displayW = Double(storedW)
        var displayH = Double(storedH)
        let (sarN, sarD) = parseAspectRatio(video?.sampleAspectRatio)
        if sarN > 0, sarD > 0, sarN != sarD {
            // Stretch the storage axis that the non-square pixels compress, so the
            // result has square pixels at the correct display aspect ratio.
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

    /// Parses an "N:M" aspect-ratio string (ffprobe's SAR form). Returns (1, 1) for
    /// nil, "N/A", or "0:1" (unknown / square).
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
