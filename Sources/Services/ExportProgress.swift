import Foundation

/// Pure progress/ETA math for the export pipeline (issue #9): parses ffmpeg's
/// `-progress pipe:1` output incrementally, maps a run's `out_time` onto the export's
/// overall fraction (keeping the established 70 % video / 30 % audio split), and turns
/// elapsed + fraction into a damped "About X remaining" label with no false precision.
///
/// Everything here is pure and unit-tested. The parsing encodes what the shell de-risk
/// found on all three formats: blocks emit about every 0.5 s of wall clock;
/// `out_time_us` and `out_time_ms` are **both microseconds** (a historical ffmpeg
/// quirk); values can be `N/A` before the first frame; `out_time` is output-timeline
/// seconds (a piece starts at 0 regardless of the source's start_time); and a
/// stream-copy run is so fast its `out_time` leaps (a 67-minute stream-copy emits
/// two blocks) — the mapping just clamps, smoothness only matters on the slow runs.
enum ExportProgress {
    /// Prefixes an ffmpeg invocation with machine-readable progress reporting on
    /// stdout. Safe for every export run: they all write their media to files, never
    /// to stdout. `-nostats` drops the human stderr ticker so error output stays clean.
    static func progressArguments(_ args: [String]) -> [String] {
        ["-progress", "pipe:1", "-nostats"] + args
    }

    /// One `key=value` line's out_time in seconds, or `nil` for any other line (including
    /// `N/A` placeholders before the first frame). `out_time_us`/`out_time_ms` are both
    /// microseconds (de-risked); `out_time` is a `HH:MM:SS.micro` clock. Negative values
    /// (a piece's leading edge) clamp to 0.
    static func outTimeSeconds(fromLine line: String) -> Double? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        switch line[..<eq] {
        case "out_time_us", "out_time_ms":
            guard let us = Double(value) else { return nil }   // skips "N/A"
            return max(0, us / 1_000_000)
        case "out_time":
            let parts = value.split(separator: ":")
            guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
                  let s = Double(parts[2]) else { return nil }
            return max(0, h * 3600 + m * 60 + s)
        default:
            return nil
        }
    }

    /// Incremental line assembly over the raw stdout chunks: a chunk can split a line
    /// anywhere, so the trailing partial line is held back until its newline arrives.
    /// `feed` returns the latest out_time among the chunk's completed lines, if any.
    struct Stream {
        private var pending = ""

        mutating func feed(_ chunk: String) -> Double? {
            pending += chunk
            let lines = pending.components(separatedBy: "\n")
            pending = lines.last ?? ""
            var latest: Double? = nil
            for line in lines.dropLast() {
                if let t = ExportProgress.outTimeSeconds(fromLine: line) { latest = t }
            }
            return latest
        }
    }

    /// One ffmpeg run's completion fraction: its output-timeline `out_time` against the
    /// seconds of output the run is expected to produce. Clamped to 0…1 (out_time can
    /// overshoot a hair on the final block); an unknown expectation reads as 0 — the
    /// overall fraction then just holds at the run's base, today's stepped behavior.
    static func runFraction(outTime: Double, expectedSeconds: Double?) -> Double {
        guard let expectedSeconds, expectedSeconds > 0 else { return 0 }
        return min(max(outTime / expectedSeconds, 0), 1)
    }

    /// Within-clip completion across a smart-render plan's segment runs, weighted by
    /// each segment's frame count: segments before `completedSegments` are done, the
    /// current one contributes `currentRunFraction` of its frames.
    static func withinClip(segmentFrames: [Int], completedSegments: Int,
                           currentRunFraction: Double) -> Double {
        let total = segmentFrames.reduce(0, +)
        guard total > 0 else { return 0 }
        let done = segmentFrames.prefix(completedSegments).reduce(0, +)
        let current = completedSegments < segmentFrames.count
            ? Double(segmentFrames[completedSegments]) * min(max(currentRunFraction, 0), 1)
            : 0
        return (Double(done) + current) / Double(total)
    }

    /// Overall fraction while producing clip `clipIndex`'s video piece: the established
    /// 70 % video phase split per clip, smoothed by the within-clip fraction.
    static func clipFraction(clipIndex: Int, clipCount: Int, withinClip: Double) -> Double {
        guard clipCount > 0 else { return 0 }
        return 0.7 * (Double(clipIndex) + min(max(withinClip, 0), 1)) / Double(clipCount)
    }

    /// Overall fraction during the `.connect` audio rebuild/mux: the 30 % tail.
    static func muxFraction(withinMux: Double) -> Double {
        0.7 + 0.3 * min(max(withinMux, 0), 1)
    }

    /// Overall fraction during `.separate` mode's per-clip mux steps.
    static func separateFraction(clipIndex: Int, clipCount: Int, withinMux: Double) -> Double {
        guard clipCount > 0 else { return 0.7 }
        return 0.7 + 0.3 * (Double(clipIndex) + min(max(withinMux, 0), 1)) / Double(clipCount)
    }

    /// Damped time-remaining estimate. The raw estimate is `elapsed × (1 − f) / f`
    /// (overall throughput so far), which jitters early and swings when the pipeline
    /// changes phase (stream-copy is hundreds of times faster than a re-encode); an
    /// exponential moving average absorbs the swings, and nothing is estimated before
    /// 2 % progress and 2 s elapsed — too little signal to be worth showing.
    struct ETAEstimator {
        private var smoothed: Double? = nil

        mutating func update(fraction: Double, elapsed: Double) -> Double? {
            guard fraction >= 0.02, elapsed >= 2 else { return nil }
            let raw = elapsed * (1 - fraction) / fraction
            smoothed = smoothed.map { 0.7 * $0 + 0.3 * raw } ?? raw
            return smoothed
        }
    }

    /// The user-facing remaining-time label (HIG: round numbers, no false precision).
    /// `nil` (no estimate yet) shows nothing; near the end — or under 10 s — it stops
    /// counting down and says "Finishing up…"; otherwise tens of seconds, then whole
    /// minutes, then half-hour steps.
    static func etaLabel(remaining: Double?, fraction: Double) -> String? {
        guard let remaining else { return nil }
        if fraction >= 0.97 || remaining < 10 { return "Finishing up…" }
        if remaining < 50 {
            let s = Int((remaining / 10).rounded(.up)) * 10
            return "About \(s) seconds remaining"
        }
        if remaining < 3300 {
            let m = max(1, Int((remaining / 60).rounded(.up)))
            return m == 1 ? "About a minute remaining" : "About \(m) minutes remaining"
        }
        let halfHours = max(2, Int((remaining / 1800).rounded()))
        let h = halfHours / 2
        if halfHours % 2 == 1 { return "About \(h)½ hours remaining" }
        return h == 1 ? "About an hour remaining" : "About \(h) hours remaining"
    }
}

/// Thread-safe wrapper pairing a `Stream` with the raw `Data` chunks ffmpeg's stdout
/// delivers (on a FileHandle queue, hence the lock). One parser per ffmpeg run.
final class ProgressParser: @unchecked Sendable {
    private var stream = ExportProgress.Stream()
    private let lock = NSLock()

    /// Feeds one stdout chunk; returns the latest out_time seconds it completed, if any.
    func feed(_ data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return stream.feed(text)
    }
}
