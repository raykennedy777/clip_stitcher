import Foundation

/// Parses the jump popover's two fields (issue #21) into frame counts. Pure,
/// fps-aware string → frame math, kept out of the view for testing. Clamping to
/// the clip is not done here — that's the seek's job.
enum JumpParser {
    /// The frame field: an integer, optionally negative (relative mode).
    static func frames(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces))
    }

    /// The time field, as a frame count at `fps`. Lenient, mirroring the readout's
    /// HH:MM:SS:FF: 1 part is bare seconds, 2 is M:S, 3 is H:M:S, 4 is H:M:S:F.
    /// Semicolon separators are accepted, and a leading "-" negates the whole
    /// value (relative mode). The frame part uses the same rounded-fps arithmetic
    /// as `CutEditorModel.timecode(forFrame:)`, so readout values round-trip.
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

    /// Resolves a parsed value to the target frame: an offset from `current` in
    /// relative mode, a position from the clip's first frame otherwise.
    static func target(value: Int, relative: Bool, current: Int) -> Int {
        relative ? current + value : value
    }
}
