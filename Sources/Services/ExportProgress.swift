import Foundation

enum ExportProgress {
    static func progressArguments(_ args: [String]) -> [String] {
        ["-progress", "pipe:1", "-nostats"] + args
    }

    static func outTimeSeconds(fromLine line: String) -> Double? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        switch line[..<eq] {
        // ADR-0034
        case "out_time_us", "out_time_ms":
            guard let us = Double(value) else { return nil }
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

    struct Stream {
        private var lines = LineAssembler()

        mutating func feed(_ chunk: String) -> Double? {
            var latest: Double? = nil
            for line in lines.feed(chunk) {
                if let t = ExportProgress.outTimeSeconds(fromLine: line) { latest = t }
            }
            return latest
        }
    }

    static func runFraction(outTime: Double, expectedSeconds: Double?) -> Double {
        guard let expectedSeconds, expectedSeconds > 0 else { return 0 }
        return min(max(outTime / expectedSeconds, 0), 1)
    }

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

    static func clipFraction(clipIndex: Int, clipCount: Int, withinClip: Double) -> Double {
        guard clipCount > 0 else { return 0 }
        return 0.7 * (Double(clipIndex) + min(max(withinClip, 0), 1)) / Double(clipCount)
    }

    static func muxFraction(withinMux: Double) -> Double {
        0.7 + 0.3 * min(max(withinMux, 0), 1)
    }

    static func separateFraction(clipIndex: Int, clipCount: Int, withinMux: Double) -> Double {
        guard clipCount > 0 else { return 0.7 }
        return 0.7 + 0.3 * (Double(clipIndex) + min(max(withinMux, 0), 1)) / Double(clipCount)
    }

    struct ETAEstimator {
        private var smoothed: Double? = nil

        mutating func update(fraction: Double, elapsed: Double) -> Double? {
            guard fraction >= 0.02, elapsed >= 2 else { return nil }
            let raw = elapsed * (1 - fraction) / fraction
            smoothed = smoothed.map { 0.7 * $0 + 0.3 * raw } ?? raw
            return smoothed
        }
    }

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
        return "About \(halfHourPhrase(remaining)) remaining"
    }

    static func halfHourPhrase(_ seconds: Double) -> String {
        let halfHours = max(2, Int((seconds / 1800).rounded()))
        let h = halfHours / 2
        if halfHours % 2 == 1 { return "\(h)½ hours" }
        return h == 1 ? "an hour" : "\(h) hours"
    }
}

final class ProgressParser: @unchecked Sendable {
    private var stream = ExportProgress.Stream()
    private let lock = NSLock()

    func feed(_ data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return stream.feed(text)
    }
}
