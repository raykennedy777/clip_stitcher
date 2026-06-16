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
    ///
    /// Every emitted frame's pts is verified (showinfo) before it is reported, and it
    /// is reported under the frame it actually is: on the open-GOP HEVC fixture the
    /// `nokey` decode silently drops some mid-stream CRAs and emits the *following*
    /// keyframe instead (measured — caching that under the requested number flashed
    /// the wrong keyframe on every step onto one). A dropped keyframe is re-fetched
    /// with a plain accurate seek — slower, but exact.
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
                    onImage(actual, image)   // a mislabel-free image, wherever it landed
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

    /// Decodes one frame at the keyframe's pts and returns it with the frame number
    /// it *actually* is — never trusted, always read back from showinfo's pts (the
    /// emitted timestamp is relative to the seek, so requested-pts + relative maps it
    /// into the index). `skipNonKey` is the fast path (`-skip_frame nokey`, 50–80 ms);
    /// without it a plain accurate seek pays the GOP warm-up but cannot miss.
    private func decodeKeyframe(at frame: Int, skipNonKey: Bool) -> (frame: Int, image: NSImage)? {
        guard frame >= 0, frame < pts.count else { return nil }
        let process = Process()
        process.executableURL = ffmpeg
        var arguments = ["-hide_banner", "-loglevel", "info", "-nostats"]
        if skipNonKey {
            arguments += ["-skip_frame", "nokey"]
        } else {
            arguments += ["-hwaccel", "videotoolbox"]   // the warm-up path; hw is faster there
        }
        arguments += [
            // -ss is measured from the container's start_time, not absolute pts (the
            // issue #3 trap).
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
        // The frame is read; stderr holds showinfo's line for it (a few hundred
        // bytes — read after the frame so neither pipe can wedge the other).
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

    /// The first frame's pts_time from showinfo output, in seconds relative to the
    /// seek point; nil when no frame was logged.
    static func firstShowinfoPts(in stderr: String) -> Double? {
        guard let range = stderr.range(of: "pts_time:") else { return nil }
        let tail = stderr[range.upperBound...].prefix(24)
        let token = tail.prefix(while: { "0123456789.-".contains($0) })
        return Double(token)
    }

    /// The frame number whose pts is nearest `target`, accepted only when within
    /// 40 % of the local frame spacing — a mismatch means the decode emitted some
    /// other frame and the image must not be filed under a guess.
    static func nearestFrame(forPts target: Double, in pts: [Double]) -> Int? {
        guard !pts.isEmpty else { return nil }
        var low = 0, high = pts.count - 1
        while low < high {
            let mid = (low + high) / 2
            if pts[mid] < target { low = mid + 1 } else { high = mid }
        }
        // `low` is the first pts >= target; the nearest is it or its predecessor.
        var best = low
        if low > 0, abs(pts[low - 1] - target) < abs(pts[low] - target) { best = low - 1 }
        let gapBefore = best > 0 ? pts[best] - pts[best - 1] : .infinity
        let gapAfter = best < pts.count - 1 ? pts[best + 1] - pts[best] : .infinity
        let spacing = min(gapBefore, gapAfter)
        let tolerance = spacing.isFinite ? spacing * 0.4 : 0.02
        return abs(pts[best] - target) <= tolerance ? best : nil
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
