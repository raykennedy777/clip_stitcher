import SwiftUI

/// State for the Output Preview (sidebar "Preview"): shows the assembled timeline by
/// decoding the right source frame for the playhead on demand — a source-stitched scrub,
/// not a rendered file (ADR-0012). The playhead moves in output frames at the target
/// clip's frame rate, mapped across every clip's selection range by `PreviewTimeline`;
/// each clip gets its own streaming decoder, switched at the joins. The decode worker /
/// cache state machine is the cut-editor's (CutEditorModel), re-scoped from one window
/// to the sidebar section.
@MainActor
final class PreviewModel: ObservableObject {
    /// Per-clip media needed at decode time, keyed by clip ID. Decoders are created
    /// lazily on first visit and all torn down when the section disappears.
    private struct ClipRuntime {
        let url: URL
        let index: FrameIndex
        let name: String
        /// The container's start_time — the decoder's and extractor's `-ss` is
        /// measured from it, not absolute pts (issue #36).
        let containerStart: Double
        let previewW: Int
        let previewH: Int
        /// The spatial conform chain for a non-matching clip (ADR-0012); nil for a
        /// matching clip, whose frames already have the canvas's shape.
        let filter: String?
        var decoder: FrameStreamDecoder?
    }

    private weak var document: ProjectDocument?

    @Published var image: NSImage?
    /// Playhead position in global output frames (0-based).
    @Published var currentFrame = 0
    /// Total output frames across the assembled timeline.
    @Published var frameCount = 0
    @Published var isLoading = true
    @Published var isPlaying = false
    /// Friendly empty-state text (no clips yet / nothing previewable) — not an error.
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    /// Name of the clip under the playhead.
    @Published var currentClipName: String?
    /// Global output frame of each join, for the scrubber's markers.
    @Published var joinFrames: [Int] = []

    /// The output frame rate (the target clip's) — what timecode and stepping use.
    private(set) var fps: Double = 25

    private var timeline: PreviewTimeline?
    private var runtimes: [UUID: ClipRuntime] = [:]
    /// Output frames the ⇧←/⇧→ keys jump between: every kept keyframe plus each
    /// join, sorted (computed once at load — the timeline is fixed while shown).
    private var keyframeAnchors: [Int] = []

    /// The output track heard during playback (issue #8) — one track at a time,
    /// exactly what the export's track would carry. Persisted per project.
    @Published var monitoredTrack = 0
    /// Per-(track × segment) audio legs mirroring the export's rebuild (ADR-0014);
    /// nil until `load`, empty tracks when no clip carries audio.
    private var audioPlan: PreviewAudioPlan?
    /// Audio playback of the monitored track. While it runs it is the master clock
    /// (ADR-0015): the play loop derives the frame on screen from elapsed audio time.
    private var audioPlayer: AudioStreamPlayer?
    /// Output-timeline seconds at the audio clock's zero (where playback started or
    /// the stream last restarted); position = `audioClockBase + elapsed`.
    private var audioClockBase: Double = 0
    /// Segment whose leg the audio stream is playing — a tick that lands in a
    /// different segment restarts the stream on that segment's leg (restart-per-leg
    /// stitching; gapless pre-spawn is a possible later upgrade).
    private var audioSegment: Int?
    /// True when this play session paces by sleep instead of the audio clock — no
    /// output tracks, or the stream never produced samples in time.
    private var audioFallback = false
    /// How long the play loop waits for the first samples before falling back
    /// (spawn-to-first-byte measures 13–25 ms; a dead stream never primes).
    private var audioPrimeDeadline = Date.distantPast

    /// The output tracks the export would carry — the audio picker's rows.
    var outputTracks: [AudioCodecPolicy.OutputAudioTrack] { audioPlan?.tracks ?? [] }

    func trackName(_ t: Int) -> String { audioPlan?.trackName(t) ?? "Track \(t + 1)" }

    /// The latest output frame the user wants that isn't satisfied yet, drained by a
    /// single decode worker toward the most recent request (same shape as the
    /// cut-editor: holding a key retargets the worker, never cancels a decode).
    private var pendingFrame: Int?
    private var pendingIsJump = false
    private var decodeTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?

    /// FIFO cache of recently shown frames, keyed by **global output frame**.
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

        // The same per-clip verdict the export uses: a clip that doesn't match the
        // target is conformed (re-timed to the target's rate); a matching clip passes
        // through 1:1 (ADR-0011, ADR-0012).
        let target = document.project.targetClip ?? clips.first { $0.video != nil }
        guard let targetVideo = target?.video, let target else {
            statusMessage = "No clip has video to preview yet."
            isLoading = false
            return
        }

        do {
            // The conform makes every output frame the target's shape, so the target's
            // display size is the canvas every clip renders onto (ADR-0012).
            let (canvasW, canvasH) = CutEditorModel.previewSize(for: targetVideo)
            var specs: [PreviewTimeline.ClipSpec] = []
            var clipAudio: [UUID: PreviewAudioPlan.ClipAudio] = [:]
            for clip in clips {
                guard let video = clip.video else { continue }   // audio-only: no frames to show
                guard let url = document.url(for: clip) else {
                    throw FFError.indexFailed("Source file not found for “\(clip.displayName)”.")
                }
                let index = try await document.frameIndex(for: clip)
                let containerStart = await MediaProbe.containerStartTime(url: url)
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
                // The clip's audio legs, resolved by the same resolver the export uses
                // (ADR-0014): one source per output track — its own stream, an external
                // file, or nil for silence. Where the export errors on a missing
                // external file, the preview degrades to silence (best-effort playback).
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
            // The same track list the export resolves (count from the richest clip,
            // formats target-first — ADR-0014), so the picker shows exactly the
            // output's tracks. The saved choice is clamped in case clips changed.
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

    // MARK: - Navigation

    func seek(to frame: Int) {
        guard frameCount > 0 else { return }
        if isPlaying { stopPlayback() }   // scrubbing/stepping pauses playback
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

    /// Jump to the previous keyframe anchor (⇧← — the cut-editor's keys). Anchors
    /// include the joins, so the jump walks back across clips; like the cut-editor's
    /// frame-0 floor, the timeline start is always an anchor.
    func stepToPreviousKeyframe() {
        if let previous = keyframeAnchors.last(where: { $0 < currentFrame }) {
            seek(to: previous)
        }
    }

    /// Jump to the next keyframe anchor (⇧→); stays put past the last one, like
    /// the cut-editor.
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

    /// Drives the decoders toward `pendingFrame`, retargeting whenever the user moves
    /// again. Only one worker runs at a time; subsequent seeks just update the target.
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

    /// Decodes (and caches) global output frame `target`, creating the clip's decoder
    /// on first use. With `maskJumpWithKeyframe` (the worker's jump path) the GOP
    /// keyframe is shown immediately to mask the seek-and-decode warm-up, and the
    /// decode is abandoned (nil) if the user has already moved on.
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
            if pendingFrame != target { return nil } // user moved on
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

    // MARK: - Playback (audio-clocked on the monitored output track — issue #8;
    // sleep-paced fallback when there is nothing to play, as shipped under ADR-0012)

    func togglePlay() { isPlaying ? stopPlayback() : play() }

    func play() {
        guard !isPlaying, frameCount > 0 else { return }
        // Playback owns the decoders while running; stand the seek worker down.
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

                // Pick the next frame to show. With the audio clock running it is
                // whatever frame the audio has reached — ahead of +1 when decode
                // lagged (frames are skipped to hold sync), or not yet due (sleep
                // until the next frame's presentation time). The output timeline is
                // uniform at the target rate, so frame ↔ time is plain arithmetic.
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
                        // Crossing a join hands the stream to the next clip's leg —
                        // a clean restart (the spawn's `-t` cap already silenced any
                        // overshoot past the old clip's out point).
                        if let (segment, _) = self.timeline?.locate(next),
                           segment != self.audioSegment {
                            self.startAudio(atFrame: next)
                        }
                    } else if Date() < self.audioPrimeDeadline {
                        // Audio spawned but hasn't produced its first samples yet.
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    } else {
                        // No samples in time — this session paces by sleep instead
                        // of stalling.
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

    /// Switches the monitored output track: persisted with the project, and a
    /// switch mid-play restarts the stream on the new track at the playhead (like
    /// the cut-editor's monitor switch).
    func setMonitoredTrack(_ slot: Int) {
        guard slot != monitoredTrack else { return }
        monitoredTrack = slot
        document?.setMonitoredOutputTrack(slot)
        if isPlaying { startAudio(atFrame: currentFrame) }
    }

    /// Starts (or restarts) the monitored track's leg at output frame `frame`,
    /// making the audio the playback clock: a real source spawns a conformed PCM
    /// decode capped to the leg's remainder; a silence-filled span spawns generated
    /// silence so the clock still runs (ADR-0014 semantics). With no output tracks
    /// at all the session paces by sleep, as before audio.
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

    /// Caches a frame the decoder produced. The cache is keyed by output frame, but the
    /// decoder reports **source** frames: in a matching segment the two map 1:1 so the
    /// whole decoded window backfills the cache; in a conformed segment several output
    /// frames can share one source frame, so only the exact frame requested is cached.
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

    // MARK: - Lifecycle

    /// Stop the worker and every clip's ffmpeg decoder. The preview is a sidebar
    /// section, not a window, so this runs on navigate-away (ADR-0012) — nothing may
    /// keep streaming once the section is hidden.
    func teardown() {
        stopPlayback()
        decodeTask?.cancel()
        decodeTask = nil
        pendingFrame = nil
        for id in runtimes.keys {
            runtimes[id]?.decoder?.stop()
            runtimes[id]?.decoder = nil
        }
        audioPlayer?.stop() // kills the audio ffmpeg process (same no-orphans rule)
        audioPlayer = nil
        cache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - Readout

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
