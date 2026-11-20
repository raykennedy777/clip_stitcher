import AppKit

final class KeyframePrefetcher {
    private let url: URL
    private let pts: [Double]
    private let containerStart: Double
    private let width: Int
    private let height: Int
    private let ffmpeg: URL
    private let queue = DispatchQueue(label: "io.github.raykennedy777.clipstitcher.kf-prefetch")
    private let lock = NSLock()
    private var process: Process?
    private var generation = 0

    init?(url: URL, index: FrameIndex, containerStart: Double, width: Int, height: Int) {
        guard let ffmpeg = try? FFTools.ffmpegURL(), width > 0, height > 0, index.count > 0 else { return nil }
        self.url = url
        self.pts = index.pts
        self.containerStart = containerStart
        self.width = width
        self.height = height
        self.ffmpeg = ffmpeg
    }

    static func neighborhood(position: Int, keyframes: [Int], cap: Int) -> [Int] {
        guard keyframes.indices.contains(position), cap > 0 else { return [] }
        var wanted = [keyframes[position]]
        var offset = 1
        while wanted.count < cap {
            let forward = position + offset
            let backward = position - offset
            if !keyframes.indices.contains(forward), !keyframes.indices.contains(backward) { break }
            if keyframes.indices.contains(forward), wanted.count < cap { wanted.append(keyframes[forward]) }
            if keyframes.indices.contains(backward), wanted.count < cap { wanted.append(keyframes[backward]) }
            offset += 1
        }
        return wanted
    }

    func fetch(_ frames: [Int], onImage: @escaping @Sendable (Int, NSImage) -> Void) {
        lock.lock()
        generation += 1
        let gen = generation
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
        queue.async {
            for frame in frames {
                guard self.isCurrent(gen) else { return }
                var delivered = false
                if let (actual, image) = self.decodeKeyframe(at: frame, skipNonKey: true) {
                    guard self.isCurrent(gen) else { return }
                    onImage(actual, image)
                    delivered = actual == frame
                }
                if !delivered {
                    guard self.isCurrent(gen) else { return }
                    if let (actual, image) = self.decodeKeyframe(at: frame, skipNonKey: false),
                       actual == frame {
                        guard self.isCurrent(gen) else { return }
                        onImage(actual, image)
                    }
                }
            }
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == gen
    }

    // ADR-0036
    private func decodeKeyframe(at frame: Int, skipNonKey: Bool) -> (frame: Int, image: NSImage)? {
        guard frame >= 0, frame < pts.count else { return nil }
        let process = Process()
        process.executableURL = ffmpeg
        process.standardInput = FileHandle.nullDevice
        var arguments = ["-hide_banner", "-loglevel", "info", "-nostats"]
        if skipNonKey {
            arguments += ["-skip_frame", "nokey"]
        } else {
            arguments += ["-hwaccel", "videotoolbox"]
        }
        arguments += [
            "-ss", String(format: "%.6f", pts[frame] - containerStart),
            "-i", url.path, "-an",
            "-vf", "showinfo,scale=\(width):\(height),format=rgb24",
            "-frames:v", "1",
            "-f", "rawvideo", "-",
        ]
        process.arguments = arguments
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        lock.lock()
        self.process = process
        do {
            try process.run()
        } catch {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let handle = pipe.fileHandleForReading
        let frameBytes = width * height * 3
        var buffer = Data()
        buffer.reserveCapacity(frameBytes)
        while buffer.count < frameBytes {
            let chunk = handle.readData(ofLength: frameBytes - buffer.count)
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        try? handle.close()
        process.terminate()
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        try? errPipe.fileHandleForReading.close()
        guard buffer.count == frameBytes,
              let relative = Self.firstShowinfoPts(in: stderr),
              let actual = Self.nearestFrame(forPts: pts[frame] + relative, in: pts),
              let image = FrameStreamDecoder.makeImage(from: buffer, width: width, height: height)
        else { return nil }
        return (actual, image)
    }

    static func firstShowinfoPts(in stderr: String) -> Double? {
        guard let range = stderr.range(of: "pts_time:") else { return nil }
        let tail = stderr[range.upperBound...].prefix(24)
        let token = tail.prefix(while: { "0123456789.-".contains($0) })
        return Double(token)
    }

    static func nearestFrame(forPts target: Double, in pts: [Double]) -> Int? {
        guard !pts.isEmpty else { return nil }
        var low = 0, high = pts.count - 1
        while low < high {
            let mid = (low + high) / 2
            if pts[mid] < target { low = mid + 1 } else { high = mid }
        }
        var best = low
        if low > 0, abs(pts[low - 1] - target) < abs(pts[low] - target) { best = low - 1 }
        let gapBefore = best > 0 ? pts[best] - pts[best - 1] : .infinity
        let gapAfter = best < pts.count - 1 ? pts[best + 1] - pts[best] : .infinity
        let spacing = min(gapBefore, gapAfter)
        let tolerance = spacing.isFinite ? spacing * 0.4 : 0.02
        return abs(pts[best] - target) <= tolerance ? best : nil
    }
}

struct BoundedLRU<Value> {
    let capacity: Int
    private var store: [Int: Value] = [:]
    private var order: [Int] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { order.count }

    func contains(_ key: Int) -> Bool { store[key] != nil }

    mutating func value(at key: Int) -> Value? {
        guard let value = store[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, at key: Int) {
        if store[key] == nil, order.count >= capacity, let oldest = order.first {
            order.removeFirst()
            store.removeValue(forKey: oldest)
        }
        store[key] = value
        touch(key)
    }

    private mutating func touch(_ key: Int) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
