import AppKit

/// Warms the cut editor's keyframe cache (issue #34). A keyframe step restarts the
/// live decoder, whose accurate seek decodes-and-discards the GOP's non-key frames
/// before the keyframe comes out — a fixed ~0.3 s on 1080p50 HEVC (measured; process
/// spawn, demux seek, and image conversion were all ≤ 2 ms). `-skip_frame nokey`
/// skips that warm-up entirely — the decoder touches only keyframes — so a short-lived
/// one-shot process yields the exact sought keyframe in tens of milliseconds.
///
/// One process per keyframe, deliberately: streaming several keyframes from one
/// `nokey` process emits them out of presentation order and drops some on the
/// open-GOP HEVC fixture (measured), which would break the frame↔image mapping.
/// Software decode, also deliberately: a lone intra frame decodes faster than a
/// VideoToolbox session warms up (50 vs 80 ms measured).
final class KeyframePrefetcher {
    private let url: URL
    private let pts: [Double]
    private let containerStart: Double
    private let width: Int
    private let height: Int
    private let ffmpeg: URL
    private let queue = DispatchQueue(label: "com.conmotogroup.vidconform.kf-prefetch")
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

    /// The keyframes worth warming around a landing: the anchor itself, then its
    /// neighbours alternating forward/backward — nearest first, so the frames a
    /// `]`/`[` press needs next arrive soonest — bounded by the cache capacity.
    /// `position` indexes into `keyframes` (the file's keyframe frame numbers).
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

    /// Fetches the given keyframes one one-shot at a time, in the order given
    /// (callers put the nearest neighbours first), calling `onImage` as each arrives
    /// (on the prefetch queue). A newer request abandons the rest of this one.
    /// `frames` must be keyframe numbers — the seek lands on that exact pts.
    func fetch(_ frames: [Int], onImage: @escaping @Sendable (Int, NSImage) -> Void) {
        lock.lock()
        generation += 1
        let gen = generation
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
        queue.async {
            for frame in frames {
                guard self.isCurrent(gen) else { return }
                guard let image = self.decodeKeyframe(at: frame) else { continue }
                guard self.isCurrent(gen) else { return }
                onImage(frame, image)
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

    private func decodeKeyframe(at frame: Int) -> NSImage? {
        guard frame >= 0, frame < pts.count else { return nil }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-skip_frame", "nokey",
            // -ss is measured from the container's start_time, not absolute pts (the
            // issue #3 trap) — corrected, the exact keyframe is the first frame out.
            "-ss", String(format: "%.6f", pts[frame] - containerStart),
            "-i", url.path, "-an",
            "-vf", "scale=\(width):\(height),format=rgb24",
            "-frames:v", "1",
            "-f", "rawvideo", "-",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
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
        guard buffer.count == frameBytes else { return nil }
        return FrameStreamDecoder.makeImage(from: buffer, width: width, height: height)
    }
}

/// A tiny bounded least-recently-used map keyed by frame number — the keyframe
/// cache's eviction policy (issue #34: ≤ ~16 entries at display resolution).
struct BoundedLRU<Value> {
    let capacity: Int
    private var store: [Int: Value] = [:]
    private var order: [Int] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { order.count }

    /// Whether `key` is cached — without refreshing its recency.
    func contains(_ key: Int) -> Bool { store[key] != nil }

    /// The cached value, refreshing its recency.
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
