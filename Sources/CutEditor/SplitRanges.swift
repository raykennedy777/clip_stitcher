import Foundation

/// The cut-editor's split-point arithmetic (issue #20, ADR-0017): which split points
/// are live inside the selection range, and the split ranges they divide it into.
/// A split at frame N makes N the first frame of the range after it, so a valid
/// split satisfies `in < N ≤ out`. Pure frame-number math, kept out of the model
/// so the rules are testable without a clip.
enum SplitRanges {
    /// One resulting clip's selection range. `nil` keeps the original open boundary
    /// (clip start / clip end), so only real cuts pin a frame number.
    struct Range: Equatable {
        var inPoint: Int?
        var outPoint: Int?
    }

    /// Whether a split point at `frame` is live under the `in < N ≤ out` rule.
    /// The same rule gates placement and decides inertness after in/out moves.
    static func isLive(_ frame: Int, inPoint: Int?, outPoint: Int?, lastFrame: Int) -> Bool {
        frame > (inPoint ?? 0) && frame <= (outPoint ?? lastFrame)
    }

    /// The split points that take effect at confirm: the live ones, in frame order.
    static func liveSplits(_ splits: Set<Int>, inPoint: Int?, outPoint: Int?, lastFrame: Int) -> [Int] {
        splits.filter { isLive($0, inPoint: inPoint, outPoint: outPoint, lastFrame: lastFrame) }.sorted()
    }

    /// Divides the selection range at the live split points. The first range keeps
    /// the original (possibly open) in point and the last the original out point;
    /// every range in between is pinned on both sides. No splits → the selection
    /// range unchanged, as a single element.
    static func ranges(splits: Set<Int>, inPoint: Int?, outPoint: Int?, lastFrame: Int) -> [Range] {
        let live = liveSplits(splits, inPoint: inPoint, outPoint: outPoint, lastFrame: lastFrame)
        var result: [Range] = []
        var start = inPoint
        for split in live {
            result.append(Range(inPoint: start, outPoint: split - 1))
            start = split
        }
        result.append(Range(inPoint: start, outPoint: outPoint))
        return result
    }
}
