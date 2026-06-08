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
    /// Decode timestamp (seconds) of each frame, parallel to `pts`. The segment muxer
    /// cuts on *decode* time, which differs from presentation time when B-frames are
    /// present, so the cut time (`segmentTime(forCutAt:)`) is derived from this, not
    /// from `pts` (ADR-0008). Defaults to `pts` for B-frame-free data, where the two
    /// orders coincide.
    let dts: [Double]
    /// Whether each frame is a keyframe (seek anchor).
    let keyframeFlags: [Bool]
    /// Whether each frame is a *clean cut point* — a closed-GOP keyframe safe for a
    /// pure stream-copy cut, with no leading pictures depending across it (ADR-0008).
    /// A subset of the keyframes. Populated by the index builder; empty until then.
    let cleanCutFlags: [Bool]

    init(pts: [Double], dts: [Double]? = nil, keyframeFlags: [Bool], cleanCutFlags: [Bool] = []) {
        self.pts = pts
        self.dts = dts ?? pts
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
    /// frame `n`. The muxer cuts at the first keyframe whose **decode** time is `>=` the
    /// requested time, so the value is the midpoint between frame `n`'s DTS and the DTS
    /// of the packet decoded immediately before it (the largest DTS below `n`'s). The
    /// midpoint sits safely under `n`'s DTS, dodging a float `>=` edge that would
    /// otherwise bump the cut to the next keyframe (ADR-0008). When B-frames reorder the
    /// stream this differs from a PTS midpoint, which can fall *after* the keyframe's DTS
    /// and skip it. For the first-decoded frame there is no predecessor, so the cut sits
    /// just before its DTS.
    ///
    /// The segment muxer measures `-segment_times` *relative to the stream's start_time*
    /// (the first presentation PTS), so that offset is subtracted: a source starting at,
    /// say, 0.24s would otherwise cut one keyframe late. Streams starting at zero are
    /// unaffected (the offset is 0).
    func segmentTime(forCutAt n: Int) -> Double {
        let startOffset = pts.first ?? 0
        let cut = dts[n]
        var predecessor: Double? = nil
        for d in dts where d < cut {
            if predecessor == nil || d > predecessor! { predecessor = d }
        }
        guard let prev = predecessor else { return cut / 2 - startOffset }
        return (prev + cut) / 2 - startOffset
    }
}
