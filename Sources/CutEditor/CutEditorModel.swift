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
    private var extractTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?

    /// Frames as compressed PNG **data** keyed by frame number, batch-filled around
    /// the current position. Storing bytes (not decoded images) keeps the cache to
    /// a few MB; only the displayed frame is decoded into an `NSImage`.
    private var cache: [Int: Data] = [:]
    private let windowBack = 6
    private let windowAhead = 30
    private let cacheCap = 240

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
            let built = try await FrameIndexer.buildIndex(url: url)
            index = built
            frameCount = built.count
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
        let clamped = min(max(0, frame), max(0, index.count - 1))
        currentFrame = clamped

        // Instant path: serve from cache and keep the window topped up ahead.
        if let cached = cache[clamped] {
            image = NSImage(data: cached)
            prefetchForward(from: clamped)
            return
        }

        // Cache miss: debounce, then batch-decode a window around the target.
        extractTask?.cancel()
        extractTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
            await self.loadWindow(around: clamped, index: index)
            if Task.isCancelled { return }
            if self.currentFrame == clamped, let data = self.cache[clamped] {
                self.image = NSImage(data: data)
                self.prefetchForward(from: clamped)
            }
        }
    }

    func step(by delta: Int) { seek(to: currentFrame + delta) }
    func goToStart() { seek(to: 0) }
    func goToEnd() { seek(to: lastFrame) }

    /// Batch-decodes a window around `n` into the cache, backfilling `n` itself with
    /// a single-frame decode if the window missed it (e.g. the final frame).
    private func loadWindow(around n: Int, index: FrameIndex) async {
        let lo = max(0, n - windowBack)
        let hi = min(index.count - 1, n + windowAhead)
        let frames = (try? await FrameExtractor.images(url: url, index: index, from: lo, to: hi)) ?? [:]
        merge(frames)
        if cache[n] == nil, let single = try? await FrameExtractor.imageData(url: url, index: index, frame: n) {
            cache[n] = single
        }
    }

    /// When stepping forward into the tail of the cached window, decode the next
    /// window ahead in the background so forward stepping stays instant.
    private func prefetchForward(from n: Int) {
        guard let index, prefetchTask == nil else { return }
        let nextStart = n + windowAhead / 2
        guard nextStart < index.count, cache[nextStart] == nil else { return }
        let lo = n + 1
        let hi = min(index.count - 1, n + windowAhead)
        guard lo <= hi else { return }
        prefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let frames = (try? await FrameExtractor.images(url: self.url, index: index, from: lo, to: hi)) ?? [:]
            self.merge(frames)
            self.prefetchTask = nil
        }
    }

    /// Inserts frame data and evicts entries farthest from the current position
    /// once the cache exceeds its cap.
    private func merge(_ frames: [Int: Data]) {
        for (frame, data) in frames { cache[frame] = data }
        guard cache.count > cacheCap else { return }
        let half = cacheCap / 2
        let keep = (currentFrame - half)...(currentFrame + half)
        for key in cache.keys where !keep.contains(key) { cache[key] = nil }
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
        stop()
        document?.setInOut(id: clip.id, inPoint: inPoint, outPoint: outPoint)
        onClose?()
    }

    /// Cancel: close without writing the selection back.
    func cancel() {
        stop()
        onClose?()
    }

    // MARK: - Playback (best-effort, no audio in v1 — ADR-0003)

    func togglePlay() { isPlaying ? stop() : play() }

    func play() {
        guard let index, !isPlaying, frameCount > 0 else { return }
        isPlaying = true
        let frameDuration = UInt64(1_000_000_000 / max(1.0, fps))
        playTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isPlaying && !Task.isCancelled {
                let end = self.outPoint ?? (index.count - 1)
                if self.currentFrame >= end { self.isPlaying = false; break }
                let next = self.currentFrame + 1
                self.currentFrame = next
                if let cached = self.cache[next] {
                    self.image = NSImage(data: cached)
                    self.prefetchForward(from: next)
                } else if let data = try? await FrameExtractor.imageData(url: self.url, index: index, frame: next) {
                    if !self.isPlaying || Task.isCancelled { break }
                    self.image = NSImage(data: data)
                }
                try? await Task.sleep(nanoseconds: frameDuration)
            }
        }
    }

    func stop() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    // MARK: - Helpers

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
