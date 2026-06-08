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
    @Published var errorMessage: String?

    /// Set by the presenter to close this editor's window.
    var onClose: (() -> Void)?

    private var index: FrameIndex?
    private var decoder: FrameStreamDecoder?
    private var playTask: Task<Void, Never>?

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
            isIndexing = false
            seek(to: inPoint ?? 0)
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

    // MARK: - Playback (best-effort, no audio in v1 — ADR-0003)

    func togglePlay() { isPlaying ? stopPlayback() : play() }

    func play() {
        guard let index, let decoder, !isPlaying, frameCount > 0 else { return }
        // Playback owns the decoder while running; stand the seek worker down.
        decodeTask?.cancel()
        decodeTask = nil
        pendingFrame = nil
        isPlaying = true
        let frameDuration = UInt64(1_000_000_000 / max(1.0, fps))
        playTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isPlaying && !Task.isCancelled {
                let end = self.outPoint ?? (index.count - 1)
                if self.currentFrame >= end { self.isPlaying = false; break }
                let next = self.currentFrame + 1
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
                try? await Task.sleep(nanoseconds: frameDuration)
            }
        }
    }

    func stopPlayback() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    /// Stop playback and tear down the decoder process. Called on OK/Cancel and on
    /// window close so no ffmpeg process is left running.
    func teardown() {
        stopPlayback()
        decodeTask?.cancel()
        decodeTask = nil
        pendingFrame = nil
        decoder?.stop()
        decoder = nil
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
