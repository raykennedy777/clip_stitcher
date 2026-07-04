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
    /// Split points (issue #20, ADR-0017): transient cut-editor state, never
    /// persisted — confirming turns them into clip boundaries, cancel drops them.
    /// May hold inert points (outside the selection range after an in/out move);
    /// only the live ones act at confirm.
    @Published var splitPoints: Set<Int> = []
    @Published var isIndexing = true
    @Published var isPlaying = false
    @Published var isSceneScanning = false
    @Published var errorMessage: String?
    /// Drives the Go To popover's presentation (issue #21) — published so the ⌘J
    /// menu item (issue #67) can open it, alongside the readout's tap gesture, now
    /// that the window's hidden ⌘J button has retired.
    @Published var isShowingJump = false

    /// Set by the presenter to close this editor's window.
    var onClose: (() -> Void)?

    private var index: FrameIndex?
    /// Per-keyframe leading-picture counts for the loaded index (issue #96), computed
    /// once in `load()` and reused by every `setIn`/`setOut` call — `CopySafeBoundaryDetector`'s
    /// pass over DTS needs no extra ffmpeg probe, so caching just avoids repeating the scan.
    /// Empty (never populated) for a clip that never finished indexing.
    private var leadingCounts: [Int?] = []
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
    /// The frame this play session started from, deciding whether the out
    /// point stops it — see `playbackEnd`.
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

    /// Keyframe images warmed around the playhead (issue #34), so `]`/`[` keyframe
    /// steps paint instantly instead of paying the live decoder's ~0.3 s restart.
    /// Separate from the FIFO above: keyframes must survive the decode windows that
    /// would otherwise evict them. LRU, bounded.
    private var keyframeCache = BoundedLRU<NSImage>(capacity: 16)
    private var prefetcher: KeyframePrefetcher?
    /// Every keyframe's frame number, in order — the prefetch neighborhood source.
    private var keyframes: [Int] = []
    /// The anchor of the last prefetch request, so a run of seeks inside one GOP
    /// doesn't re-issue the same neighborhood.
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

    /// Whether transport (play, step, keyframe, scene) can act: a clip is loaded and
    /// no longer indexing. The cut editor's transport buttons and the Playback menu
    /// (issue #67) share this gate.
    var canStep: Bool { frameCount > 0 && !isIndexing }

    /// Whether a scene-scan jump can start — as `canStep`, and not already scanning.
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
            // Probed before the decoder exists — its seeks subtract it (issue #36).
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
            // Resume where this clip's editor was last closed; a never-opened clip
            // starts at its in point (frame 0 when none is set).
            seek(to: document?.lastViewedFrame(for: clip.id) ?? inPoint ?? 0)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isIndexing = false
        }
    }

    #if DEBUG
    /// Test seam (issue #96): installs a frame count and its leading-picture counts
    /// directly, standing in for `load()`'s real ffmpeg probe (which derives both from
    /// an ffprobe-built index) so unit tests can drive `setIn`/`setOut`'s copy-cut
    /// snapping against a known shape without spawning ffprobe on a fixture. Taking
    /// `leadingCounts` straight — rather than a keyframe/DTS pair run back through
    /// `CopySafeBoundaryDetector` — lets a test also hand-craft edge-case shapes the
    /// detector itself would never produce (e.g. to pin down a defensive clamp in the
    /// consuming code). `keyframeFlags` in the installed index are irrelevant to
    /// `setIn`/`setOut` and left empty; `pts` are synthetic but monotonic so `seek`'s
    /// clamping and cache bookkeeping behave normally. Clears `isIndexing` so the
    /// transport gates read as loaded.
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

    // MARK: - Navigation

    func seek(to frame: Int) {
        guard let index else { return }
        if isPlaying { stopPlayback() }   // any user seek pauses playback (ADR-0015 amendment)
        let previous = currentFrame
        let clamped = min(max(0, frame), max(0, index.count - 1))
        currentFrame = clamped

        // Warm the keyframes around wherever the playhead lands (issue #34), so the
        // next `]`/`[` press paints from cache.
        prefetchNeighborhood(around: clamped)

        // Instant path: a recently-decoded frame (e.g. stepping back over the cache).
        if let cached = cache[clamped] {
            image = cached
            pendingFrame = nil
            return
        }

        // Prefetched keyframe (issue #34): paint instantly, then fall through so the
        // live decoder still re-anchors here — subsequent single-frame steps stay
        // frame-accurate, and its decode of this same frame repaints identical pixels.
        let warmed = keyframeCache.value(at: clamped)
        if let warmed {
            image = warmed
        }

        // Otherwise hand the frame to the decode worker. A move beyond a contiguous
        // run is a "jump" worth an instant keyframe preview; ±1 steps are not (a
        // keyframe flash there would be jarring). A frame already painted from the
        // keyframe cache needs no preview flash either.
        pendingFrame = clamped
        pendingIsJump = warmed == nil && abs(clamped - previous) > cacheCap
        startDecodeWorker()
    }

    /// Issues a prefetch for the keyframes around `frame`, nearest first — once per
    /// anchor keyframe, never during playback (the player owns the pipeline then),
    /// and only for frames not already warmed. Arriving images land in the keyframe
    /// cache; one that the user is still waiting on paints immediately, which is what
    /// makes an *uncached* keyframe step fast too (~50–80 ms instead of ~0.3 s).
    private func prefetchNeighborhood(around frame: Int) {
        guard !isPlaying, let index, let prefetcher, !keyframes.isEmpty else { return }
        // No keyframe at/before the frame → nothing to warm around; skip the prefetch.
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
                // Paint only if the user is still waiting on exactly this frame —
                // the decode worker's accurate repaint owns the frame after that.
                if self.currentFrame == frame, self.pendingFrame == frame {
                    self.image = image
                }
            }
        }
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

    // MARK: - Save frame as image (issue #89)

    /// Whether a frame is on screen to save — the menu item's / shortcut's enabled state.
    var canSaveFrame: Bool { image != nil && index != nil }

    /// A request to save the displayed frame as a full-resolution PNG (issue #89) at the
    /// source's **coded** dimensions (storage pixels — anamorphic content saves at its
    /// storage shape, not the SAR-corrected display shape shown on screen). The cut-editor
    /// never deinterlaces its preview (`FrameStreamDecoder` scales only), so the still is
    /// woven exactly as displayed — matching what-you-see for a field-coded source. `nil`
    /// when nothing is loaded.
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

    /// Jump to the nearest keyframe before the current frame. Landing on a keyframe
    /// is the decoder's cheapest seek, so these jumps feel instant.
    func stepToPreviousKeyframe() {
        guard let index, currentFrame > 0 else { return }
        // No earlier keyframe (a headless partial index) → jump to the clip start.
        seek(to: index.keyframeIndex(atOrBefore: currentFrame - 1) ?? 0)
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
    /// holds no cut, so the key always moves the playhead. Landing seeks, so a
    /// scene jump pauses playback like every other seek.
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

    /// Whether a mark on this clip routes through copy-cut snapping (issue #96): a
    /// field-coded source whose codec the snap-safe recipe covers (H.264 — the same gate
    /// Clip Doctor's field-coded repair uses, `FieldCodedSupport.canRepairFieldCoded`).
    /// `fieldCoded == nil` (still probing) does not snap — only a *confirmed*
    /// field-coded clip needs its cut points kept off partial-GOP boundaries. Every other
    /// clip (progressive, or field-coded in an unsupported codec) marks the raw playhead
    /// frame exactly as before. Reads the **live** clip from the document (this model's
    /// `clip` is a snapshot from when the window opened, like `monitoredAudioSource`),
    /// so a field-coded probe that resolves while the editor is open routes subsequent
    /// marks through snapping immediately instead of leaving the whole session raw.
    private var snapsCutPoints: Bool {
        let live = document?.project.clips.first { $0.id == clip.id } ?? clip
        return FieldCodedSupport.requiresCopyOnlyCuts(fieldCoded: live.fieldCoded, codec: live.video?.codec)
    }

    /// The frame a mark at the playhead actually lands on: the raw playhead frame, or —
    /// on the copy-cut route — its position snapped through `snap`. `nil` means snapping
    /// was required but no valid boundary exists (no candidate in the index, or the
    /// index isn't built yet — `leadingCounts` still empty): the caller must treat the
    /// press as a **non-destructive no-op**, leaving any existing points untouched.
    private func markTarget(_ snap: (Int, [Int?]) -> Int?) -> Int? {
        snapsCutPoints ? snap(currentFrame, leadingCounts) : currentFrame
    }

    /// Marks the in point at the playhead — snapped to the nearest copy-safe keyframe
    /// first on the copy-cut route (issue #96) — then the existing conflict rule (an out
    /// point now before the new in point is cleared) applied to the *landed* value, so
    /// the two points can never straddle a partial-GOP edge the copy-cut export can't
    /// honor. The playhead follows a snap so the marker visibly lands where the cut will
    /// happen. No valid boundary (`markTarget` nil) → a non-destructive no-op.
    func setIn() {
        guard let target = markTarget(CopyCutSnapper.snapInPoint) else { return }
        inPoint = target
        if let out = outPoint, out < target { outPoint = nil }
        if target != currentFrame { seek(to: target) }
    }

    /// Marks the out point at the playhead — snapped first (issue #96) as `setIn` does —
    /// then the conflict rule applied to the landed value. A *snapped* boundary landing
    /// on the clip's own last frame stores nil (open clip end = copy to EOF) rather than
    /// the explicit index — `ExportPlanner`/the copy-cut planner only give the no-cut
    /// copy-to-EOF treatment to `outPoint == nil`, so an explicit last-frame value would
    /// force a needless tail re-encode; the playhead still moves there so the marker
    /// visibly lands. (A progressive clip storing an explicit last-frame out is
    /// unchanged pre-#96 behavior.) No valid boundary → a non-destructive no-op that
    /// leaves an existing out point untouched.
    func setOut() {
        guard let target = markTarget(CopyCutSnapper.snapOutPoint) else { return }
        outPoint = snapsCutPoints && target == lastFrame ? nil : target
        if let start = inPoint, start > target { inPoint = nil }
        if target != currentFrame { seek(to: target) }
    }

    // MARK: - Split points (issue #20)

    /// Whether ⌘B can act at the playhead: a split at frame N starts the range
    /// [N … out], so N must lie strictly inside the selection range (in < N ≤ out).
    var canToggleSplit: Bool {
        frameCount > 0 && SplitRanges.isLive(
            currentFrame, inPoint: inPoint, outPoint: outPoint, lastFrame: lastFrame)
    }

    var isSplitAtPlayhead: Bool { splitPoints.contains(currentFrame) }

    /// The split points that will act at confirm, in frame order.
    var liveSplitPoints: [Int] {
        SplitRanges.liveSplits(splitPoints, inPoint: inPoint, outPoint: outPoint, lastFrame: lastFrame)
    }

    /// Split points stranded outside the selection range by an in/out move — kept
    /// (drawn dimmed) so widening the range revives them, ignored at confirm.
    var inertSplitPoints: [Int] {
        splitPoints.subtracting(liveSplitPoints).sorted()
    }

    /// Adds a split point at the playhead, or removes the one already there. On the
    /// copy-cut route (issue #96) the split lands snapped on the nearest copy-safe
    /// keyframe — `CopyCutSnapper.snapInPoint`, because a split at keyframe `k` is valid
    /// for BOTH resulting pieces: the next piece starts at `k` (a legal copy start), and
    /// the previous piece's inclusive out `k − 1` equals `k − count − 1` with count 0 (a
    /// legal copy end). The toggle operates on the *snapped* frame, so pressing split
    /// while parked mid-GOP near an existing snapped split removes it instead of
    /// stacking a second point, and the playhead follows the snap (like `setIn`) so the
    /// marker lands visibly. No valid boundary (`markTarget` nil) → a no-op.
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

    /// OK: write the selection back to the document — as one in/out pair, or as a
    /// clip-per-split-range replacement when live split points exist — then close.
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
                sourceTime: index.pts[frame], containerStartTime: containerStartTime),
            filter: source.mixFilter)
    }

    /// The monitored audio slot resolved to a playable source: the clip's own file
    /// and stream, or an external file's chosen stream (aligned file start =
    /// video-file start, ADR-0014 — the same seek offset applies), plus the slot's
    /// channel-mix filter (ADR-0019 — the same mix the export inserts, so what is
    /// monitored is what ships). Reads the live clip — the dropdown and settings
    /// sheet write to the document, and this model's `clip` is a snapshot from when
    /// the window opened. nil when there is nothing playable: no slots, a slot past
    /// the clip's own streams (silence), or an external bookmark that no longer
    /// resolves.
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
        prefetcher?.stop() // kills any in-flight keyframe one-shot (same no-orphans rule)
        prefetcher = nil
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
