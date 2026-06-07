import Foundation

/// Per-clip frame index in **presentation order** (sorted by PTS), the basis of
/// frame-accurate seeking (ADR-0006). Built lazily when the cut-editor opens.
///
/// Packets come out of ffprobe in *decode* order, which differs from presentation
/// order whenever B-frames are present, so the entries are sorted by PTS: index N
/// is the Nth frame the viewer sees.
struct FrameIndex {
    /// Presentation timestamp (seconds) of each frame, ascending.
    let pts: [Double]
    /// Whether each frame is a keyframe (seek anchor).
    let keyframeFlags: [Bool]

    var count: Int { pts.count }

    /// The nearest keyframe at or before frame `n` — the safe seek anchor for
    /// decoding forward to `n`.
    func keyframeIndex(atOrBefore n: Int) -> Int {
        var anchor = 0
        var i = min(n, keyframeFlags.count - 1)
        while i >= 0 {
            if keyframeFlags[i] { anchor = i; break }
            i -= 1
        }
        return anchor
    }
}
