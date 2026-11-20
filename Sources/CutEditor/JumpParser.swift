import Foundation

enum JumpParser {
    static func frames(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces))
    }

    static func timecodeFrames(_ text: String, fps: Double) -> Int? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ";", with: ":")
        guard !trimmed.isEmpty else { return nil }
        var negative = false
        if trimmed.hasPrefix("-") {
            negative = true
            trimmed.removeFirst()
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }

        let seconds: Int
        var frames = 0
        switch numbers.count {
        case 1: seconds = numbers[0]
        case 2: seconds = numbers[0] * 60 + numbers[1]
        case 3: seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default:
            seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
            frames = numbers[3]
        }
        let total = seconds * max(1, Int(fps.rounded())) + frames
        return negative ? -total : total
    }

    static func target(value: Int, relative: Bool, current: Int) -> Int {
        relative ? current + value : value
    }

    static func steppedFrames(_ text: String, by delta: Int, allowNegative: Bool) -> String? {
        guard let value = frames(text) else { return nil }
        let stepped = value + delta
        return String(allowNegative ? stepped : max(0, stepped))
    }

    static func steppedTimecode(_ text: String, by delta: Int, fps: Double,
                                allowNegative: Bool) -> String? {
        guard let value = timecodeFrames(text, fps: fps) else { return nil }
        let stepped = value + delta
        return timecode(forFrames: allowNegative ? stepped : max(0, stepped), fps: fps)
    }

    static func timecode(forFrames frames: Int, fps: Double) -> String {
        let fpsInt = max(1, Int(fps.rounded()))
        let magnitude = abs(frames)
        let totalSeconds = magnitude / fpsInt
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        let f = magnitude % fpsInt
        return (frames < 0 ? "-" : "") + String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }
}
