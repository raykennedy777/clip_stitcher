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

    init(pts: [Double], dts: [Double]? = nil, keyframeFlags: [Bool]) {
        self.pts = pts
        self.dts = dts ?? pts
        self.keyframeFlags = keyframeFlags
    }

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

    /// The `-segment_times` value that makes the ffmpeg segment muxer cut exactly at
    /// frame `n`. The muxer cuts at the first keyframe whose **decode** time is `>=` the
    /// requested time, so the value is the midpoint between frame `n`'s DTS and the DTS
    /// of the packet decoded immediately before it (the largest DTS below `n`'s). The
    /// midpoint sits safely under `n`'s DTS, dodging a float `>=` edge that would
    /// otherwise bump the cut to the next keyframe (ADR-0008). When B-frames reorder the
    /// stream this differs from a PTS midpoint, which can fall *after* the keyframe's DTS
    /// and skip it.
    ///
    /// The segment muxer measures `-segment_times` *relative to the stream's start_time*
    /// (the first presentation PTS), so that offset is subtracted: a source starting at,
    /// say, 0.24s would otherwise cut one keyframe late. Streams starting at zero are
    /// unaffected (the offset is 0).
    ///
    /// When `n` is the first-*decoded* frame there is no predecessor, so the cut is the
    /// file start: any time at or below `n`'s (offset-relative) DTS selects it, and there
    /// is no earlier keyframe to skip onto. `cut/2 - startOffset` is always ≤ that relative
    /// DTS (`cut - startOffset`) for `cut ≥ 0`, so it selects `n`. The relative value is
    /// legitimately negative on a stream whose first DTS precedes its first PTS — that just
    /// means "cut at/before the start", which is correct here. (In practice this branch is
    /// unreachable for a real cut: a copy boundary is never the first-decoded frame.)
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
