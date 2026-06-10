import AppKit

/// A long-lived ffmpeg process that streams decoded frames as raw RGB over a pipe,
/// so sequential stepping costs one frame read (~1-2 ms) instead of spawning a new
/// process and re-decoding from the keyframe every time (ADR-0003's deferred
/// upgrade).
///
/// The process decodes forward from a seek point; `image(at:)` reads ahead to the
/// requested frame, and restarts at the nearest keyframe only when the target is
/// behind the playhead or in a later GOP. Blocking pipe reads run on a dedicated
/// serial queue (never the main thread or the Swift concurrency pool).
final class FrameStreamDecoder {
    /// The frame requested plus the trailing run of frames decoded on the way to
    /// it — so the caller can populate its cache and serve backward steps within
    /// that run without forcing another keyframe-seek-and-decode.
    struct Result {
        let image: NSImage?
        let window: [(frame: Int, image: NSImage)]
    }

    private let url: URL
    private let index: FrameIndex
    private let width: Int
    private let height: Int
    private let useHardware: Bool
    /// Replaces the default `scale=W:H` when set (the preview's spatial conform chain,
    /// ADR-0012). Must be 1-frame-in-1-frame-out — the seek arithmetic counts frames —
    /// and must emit exactly `width`×`height` (the pipe reads fixed-size frames).
    private let filter: String?
    private let ffmpeg: URL
    private let queue = DispatchQueue(label: "com.conmotogroup.vidconform.decoder")

    /// How many trailing frames to materialise when decoding forward through a GOP.
    /// Matches the model's cache cap so a run of backward steps stays in cache.
    private let windowSize: Int

    private var process: Process?
    private var handle: FileHandle?
    private var nextFrame = 0

    private var frameBytes: Int { width * height * 3 }

    init?(url: URL, index: FrameIndex, width: Int, height: Int, useHardware: Bool,
          filter: String? = nil, windowSize: Int = 48) {
        guard let ffmpeg = try? FFTools.ffmpegURL(), width > 0, height > 0, index.count > 0 else { return nil }
        self.url = url
        self.index = index
        self.width = width
        self.height = height
        self.useHardware = useHardware
        self.filter = filter
        self.ffmpeg = ffmpeg
        self.windowSize = max(1, windowSize)
    }

    /// Returns the image for presentation frame `n` along with the trailing run of
    /// frames decoded to reach it, reading the stream forward or restarting at the
    /// nearest keyframe as needed. `image` is nil only on decode failure (caller
    /// should fall back to `FrameExtractor`).
    func image(at n: Int) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.imageSync(at: n)) }
        }
    }

    /// If reaching frame `n` requires a keyframe seek + decode (a jump or a
    /// backward miss), restarts the stream at the anchor keyframe and returns just
    /// that keyframe — one cheap frame read — so the caller can show it instantly
    /// while the exact frame decodes. Leaves the stream positioned to continue
    /// forward to `n`. Returns nil when no restart is needed (contiguous forward
    /// stepping) or when `n` is itself the keyframe (the exact frame is already cheap).
    func keyframePreview(forFrameAt n: Int) async -> (frame: Int, image: NSImage)? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.keyframePreviewSync(at: n)) }
        }
    }

    func stop() {
        queue.async { self.stopSync() }
    }

    // MARK: - Queue-confined work

    private func imageSync(at n: Int) -> Result {
        let target = min(max(0, n), index.count - 1)
        let anchor = index.keyframeIndex(atOrBefore: target)

        // Restart if we have no stream, the target is behind us, or its keyframe is
        // ahead of the playhead (a later GOP — cheaper to seek than decode through).
        if process == nil || target < nextFrame || anchor > nextFrame {
            start(seekingTo: anchor)
        }

        // Materialise only the trailing window of frames we pass through, so a run
        // of backward steps over this GOP is served from the caller's cache rather
        // than re-seeking the keyframe and re-decoding for every single frame.
        let windowStart = max(0, target - windowSize + 1)
        var targetImage: NSImage?
        var window: [(frame: Int, image: NSImage)] = []
        while nextFrame <= target {
            guard let frame = readFrame() else { break }
            if nextFrame >= windowStart,
               let image = Self.makeImage(from: frame, width: width, height: height) {
                window.append((nextFrame, image))
                if nextFrame == target { targetImage = image }
            }
            nextFrame += 1
        }

        return Result(image: targetImage, window: window)
    }

    private func keyframePreviewSync(at n: Int) -> (frame: Int, image: NSImage)? {
        let target = min(max(0, n), index.count - 1)
        let anchor = index.keyframeIndex(atOrBefore: target)

        // Only worth previewing when we'd otherwise restart-and-decode a GOP, and
        // only when the keyframe isn't the target itself.
        let needsRestart = process == nil || target < nextFrame || anchor > nextFrame
        guard needsRestart, anchor != target else { return nil }

        start(seekingTo: anchor)
        guard let data = readFrame() else { return nil }
        nextFrame = anchor + 1
        guard let image = Self.makeImage(from: data, width: width, height: height) else { return nil }
        return (anchor, image)
    }

    private func start(seekingTo anchor: Int) {
        stopSync()
        let process = Process()
        process.executableURL = ffmpeg
        var arguments = ["-hide_banner", "-loglevel", "error"]
        if useHardware { arguments += ["-hwaccel", "videotoolbox"] }
        arguments += [
            "-ss", String(format: "%.6f", index.pts[anchor]),
            "-i", url.path, "-an",
            "-vf", "\(filter ?? "scale=\(width):\(height)"),format=rgb24",
            "-f", "rawvideo", "-",
        ]
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        self.process = process
        self.handle = pipe.fileHandleForReading
        self.nextFrame = anchor
    }

    private func readFrame() -> Data? {
        guard let handle else { return nil }
        var buffer = Data()
        buffer.reserveCapacity(frameBytes)
        while buffer.count < frameBytes {
            let chunk = handle.readData(ofLength: frameBytes - buffer.count)
            if chunk.isEmpty { return nil } // EOF
            buffer.append(chunk)
        }
        return buffer
    }

    private func stopSync() {
        if let process, process.isRunning { process.terminate() }
        try? handle?.close()
        process = nil
        handle = nil
    }

    /// Shared with `KeyframePrefetcher` — both read the same raw RGB frame layout.
    static func makeImage(from data: Data, width: Int, height: Int) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 3, bitsPerPixel: 24
        ), let destination = rep.bitmapData else { return nil }

        data.withUnsafeBytes { source in
            if let base = source.baseAddress {
                memcpy(destination, base, min(data.count, width * height * 3))
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}
