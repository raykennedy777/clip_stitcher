import AppKit
import os

final class FrameStreamDecoder {
    struct Result {
        let image: NSImage?
        let window: [(frame: Int, image: NSImage)]
    }

    private let url: URL
    private let index: FrameIndex
    private let containerStart: Double
    private let width: Int
    private let height: Int
    private let useHardware: Bool
    private let filter: String?
    private let ffmpeg: URL
    private let queue = DispatchQueue(label: "io.github.raykennedy777.clipstitcher.decoder")
    private static let log = Logger(subsystem: "io.github.raykennedy777.clipstitcher",
                                    category: "FrameStreamDecoder")

    private let windowSize: Int

    private var process: Process?
    private var handle: FileHandle?
    private var errPipe: Pipe?
    // ADR-0034, ADR-0036
    private var stderrTail: StderrTail?
    private var nextFrame = 0

    private var frameBytes: Int { width * height * 3 }

    init?(url: URL, index: FrameIndex, containerStart: Double, width: Int, height: Int,
          useHardware: Bool, filter: String? = nil, windowSize: Int = 48) {
        guard let ffmpeg = try? FFTools.ffmpegURL(), width > 0, height > 0, index.count > 0 else { return nil }
        self.url = url
        self.index = index
        self.containerStart = containerStart
        self.width = width
        self.height = height
        self.useHardware = useHardware
        self.filter = filter
        self.ffmpeg = ffmpeg
        self.windowSize = max(1, windowSize)
    }

    func image(at n: Int) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.imageSync(at: n)) }
        }
    }

    func keyframePreview(forFrameAt n: Int) async -> (frame: Int, image: NSImage)? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.keyframePreviewSync(at: n)) }
        }
    }

    func stop() {
        queue.async { self.stopSync() }
    }

    private func imageSync(at n: Int) -> Result {
        let target = min(max(0, n), index.count - 1)
        let anchor = index.keyframeIndex(atOrBefore: target) ?? 0

        if process == nil || target < nextFrame || anchor > nextFrame {
            start(seekingTo: anchor)
        }

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

        if targetImage == nil { logDecodeFailure(target: target) }
        return Result(image: targetImage, window: window)
    }

    private func keyframePreviewSync(at n: Int) -> (frame: Int, image: NSImage)? {
        let target = min(max(0, n), index.count - 1)
        let anchor = index.keyframeIndex(atOrBefore: target) ?? 0

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
        process.standardInput = FileHandle.nullDevice
        var arguments = ["-hide_banner", "-loglevel", "error"]
        if useHardware { arguments += ["-hwaccel", "videotoolbox"] }
        arguments += [
            "-ss", String(format: "%.6f", Self.seekSeconds(forPts: index.pts[anchor],
                                                           containerStart: containerStart)),
            "-i", url.path, "-an",
            "-vf", "\(filter ?? "scale=\(width):\(height)"),format=rgb24",
            "-f", "rawvideo", "-",
        ]
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe

        let errPipe = Pipe()
        let tail = StderrTail(cap: 64 * 1024)
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { tail.append(chunk) }
        }
        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            Self.log.error("ffmpeg failed to launch: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.process = process
        self.handle = pipe.fileHandleForReading
        self.errPipe = errPipe
        self.stderrTail = tail
        self.nextFrame = anchor
    }

    private func readFrame() -> Data? {
        guard let handle else { return nil }
        var buffer = Data()
        buffer.reserveCapacity(frameBytes)
        while buffer.count < frameBytes {
            let chunk = handle.readData(ofLength: frameBytes - buffer.count)
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
        return buffer
    }

    private func stopSync() {
        if let process, process.isRunning { process.terminate() }
        try? handle?.close()
        errPipe?.fileHandleForReading.readabilityHandler = nil
        try? errPipe?.fileHandleForReading.close()
        process = nil
        handle = nil
        errPipe = nil
        stderrTail = nil
    }

    private func logDecodeFailure(target: Int) {
        if let errPipe, process?.isRunning != true {
            let reader = errPipe.fileHandleForReading
            reader.readabilityHandler = nil
            if let remaining = try? reader.readToEnd(), !remaining.isEmpty {
                stderrTail?.append(remaining)
            }
        }
        guard let data = stderrTail?.snapshot(), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return }
        Self.log.error("decode failed reaching frame \(target, privacy: .public); falling back to FrameExtractor. ffmpeg: \(text, privacy: .public)")
    }

    static func seekSeconds(forPts pts: Double, containerStart: Double) -> Double {
        max(0, pts - containerStart)
    }

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
