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
    /// Decode timestamp (seconds) of each frame, parallel to `pts`. The cut time
    /// (`segmentTime(forCutAt:)`) starts from a DTS midpoint (ADR-0008), which differs
    /// from a PTS midpoint when B-frames are present. Defaults to `pts` for
    /// B-frame-free data, where the two orders coincide.
    let dts: [Double]
    /// Whether each frame is a keyframe (seek anchor).
    let keyframeFlags: [Bool]

    init(pts: [Double], dts: [Double]? = nil, keyframeFlags: [Bool]) {
        self.pts = pts
        self.dts = dts ?? pts
        self.keyframeFlags = keyframeFlags
    }

    var count: Int { pts.count }

    /// The presentation span the index covers in seconds: last pts − first pts. A
    /// progress-denominator fallback when a clip's probed `duration` is unknown (issue
    /// #81) — the mux and verify bands need *some* positive expectation to advance, and
    /// read as 0 (a frozen bar) without one. Zero for an empty or single-frame index.
    var durationSpan: Double {
        guard let first = pts.first, let last = pts.last, last > first else { return 0 }
        return last - first
    }

    /// The nearest keyframe at or before frame `n` — the safe seek anchor for decoding
    /// forward to `n` / the safe stream-copy boundary. `nil` when no keyframe exists in
    /// `[0, n]`: an empty index, or a partial/damaged index whose head precedes its first
    /// keyframe. The old contract returned 0 there, silently handing callers a *non*-keyframe
    /// anchor — a copy boundary that can't be cut on, or a seek/relative-frame base that
    /// skews the decode count. Callers now decide their own degraded behavior explicitly.
    func keyframeIndex(atOrBefore n: Int) -> Int? {
        var i = min(n, keyframeFlags.count - 1)
        while i >= 0 {
            if keyframeFlags[i] { return i }
            i -= 1
        }
        return nil
    }

    /// The first keyframe strictly after frame `n`, or nil when no later keyframe
    /// exists — the cut-editor's "next keyframe" jump target.
    func keyframeIndex(after n: Int) -> Int? {
        let start = max(0, n + 1)
        guard start < keyframeFlags.count else { return nil }
        for i in start..<keyframeFlags.count where keyframeFlags[i] {
            return i
        }
        return nil
    }

    /// The frame on screen at source presentation time `t`: the last frame whose
    /// pts is at or before `t`, clamped to the first frame for times before the
    /// stream starts. Binary search — the audio-clocked playback loop calls this
    /// every tick (issue #7).
    func frameIndex(atOrBeforeTime t: Double) -> Int {
        guard let first = pts.first, t >= first else { return 0 }
        var low = 0
        var high = pts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if pts[mid] <= t { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The `-segment_times` value that makes the ffmpeg segment muxer cut exactly at
    /// frame `n`. The value is the midpoint between frame `n`'s DTS and the DTS of the
    /// packet decoded immediately before it (the largest DTS below `n`'s). The midpoint
    /// sits safely under `n`'s DTS, dodging a float `>=` edge that would otherwise bump
    /// the cut to the next keyframe (ADR-0008).
    ///
    /// The muxer splits at the first keyframe, in decode order, whose **presentation**
    /// time is `>=` the requested time. So the midpoint is right only while every keyframe
    /// decoded before `n` presents below it. A keyframe decoded just before `n` — two
    /// I-frames back to back, or an I-frame and one B-frame — presents above it, and the
    /// muxer then splits one keyframe early: the copy loses that keyframe and every
    /// picture decoded between the two. In that case the value moves up to the midpoint
    /// between that keyframe's PTS and `n`'s PTS. A safe midpoint stays as it is.
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
        // The latest presentation time of a keyframe decoded before `n`: the muxer splits
        // there if the cut time is at or below it.
        var earlierKeyframePts: Double? = nil
        for i in dts.indices where dts[i] < cut {
            if predecessor == nil || dts[i] > predecessor! { predecessor = dts[i] }
            if i < keyframeFlags.count, keyframeFlags[i],
               earlierKeyframePts == nil || pts[i] > earlierKeyframePts! {
                earlierKeyframePts = pts[i]
            }
        }
        guard let prev = predecessor else { return cut / 2 - startOffset }
        var time = (prev + cut) / 2
        if let k = earlierKeyframePts, k >= time, k < pts[n] {
            time = (k + pts[n]) / 2
        }
        return time - startOffset
    }
}
