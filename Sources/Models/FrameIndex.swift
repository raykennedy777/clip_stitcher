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
    /// Whether each frame is a *clean cut point* — a closed-GOP keyframe safe for a
    /// pure stream-copy cut, with no leading pictures depending across it (ADR-0008).
    /// A subset of the keyframes. Populated by the index builder; empty until then.
    let cleanCutFlags: [Bool]

    init(pts: [Double], keyframeFlags: [Bool], cleanCutFlags: [Bool] = []) {
        self.pts = pts
        self.keyframeFlags = keyframeFlags
        self.cleanCutFlags = cleanCutFlags
    }

    var count: Int { pts.count }

    /// The clean cut point (ADR-0008) nearest to frame `n`, by frame-number distance —
    /// where a requested in/out point snaps to, since Milestone 1 only cuts at clean
    /// cut points. On a tie, the earlier cut point wins (predictable).
    func nearestCleanCutPoint(to n: Int) -> Int {
        var best = 0
        var bestDistance = Int.max
        for i in cleanCutFlags.indices where cleanCutFlags[i] {
            let distance = abs(i - n)
            if distance < bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

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

    /// The `-segment_times` value that makes the ffmpeg segment muxer cut exactly at
    /// frame `n`: the midpoint between frame `n`'s PTS and the preceding frame's PTS.
    /// Sitting just below `n`'s PTS sidesteps a float `>=` edge that would otherwise
    /// bump the cut to the next keyframe (ADR-0008). For frame 0 there is no preceding
    /// frame, so the cut sits just before the first PTS.
    func segmentTime(forCutAt n: Int) -> Double {
        guard n > 0 else { return pts[0] / 2 }
        return (pts[n - 1] + pts[n]) / 2
    }
}
