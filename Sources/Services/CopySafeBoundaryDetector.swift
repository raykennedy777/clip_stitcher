import Foundation

/// Decides which keyframes are *copy-safe boundaries* for Milestone 2's boundary
/// re-encode (ADR-0009): the keyframes a stream-copied middle may start and end on
/// without dragging in **orphaned leading pictures** at the re-encode→copy seam.
///
/// This is the *general* leading-picture-free test, applied uniformly to **every**
/// codec — including MPEG-2, whose open-GOP I-frames are *not* automatically copy-safe
/// here: M2 *re-encodes* the prior GOP, so any leading pictures that reference across the
/// boundary would be orphaned at the re-encode→copy seam. A keyframe qualifies only when
/// nothing presented before it decodes later than it does.
///
/// The test reads only the per-frame DTS the frame index already carries (ADR-0006), so
/// it needs no extra ffmpeg pass and the index need not be rebuilt — which also keeps the
/// future libav minimal-recode path (Milestone 2b) open, since the per-frame
/// leading-picture structure is recoverable from the same DTS.
enum CopySafeBoundaryDetector {
    /// A presentation-order flag (parallel to `FrameIndex`) marking the keyframes a
    /// stream copy may START on. A keyframe is copy-safe when nothing presented
    /// before it decodes later than it does — i.e. it has no leading pictures
    /// (`leadingPictureCounts` of 0). Copy ENDS are looser (#16): any counted keyframe
    /// may end a span — see `leadingPictureCounts`.
    static func copySafeFlags(keyframeFlags: [Bool], dts: [Double]) -> [Bool] {
        leadingPictureCounts(keyframeFlags: keyframeFlags, dts: dts).map { $0 == 0 }
    }

    /// Per-frame leading-picture counts (parallel to `FrameIndex`): for a keyframe, how
    /// many frames present just before it but decode after it — its leading pictures
    /// (HEVC RASL frames, the B-frames before an open-GOP MPEG-2 I-frame). `nil` for
    /// non-keyframes.
    ///
    /// The counts drive the planner's asymmetric boundary rules (#16): a copy may START
    /// only at a count-0 keyframe (the strict rule above — starting at an open keyframe
    /// would orphan its leading pictures at the seam), but may END at *any* counted
    /// keyframe `K`, at presentation index `K − count`: the segment-muxer cut just
    /// before `K`'s DTS sends exactly those leading pictures into the discarded segment
    /// (verified in the shell against the real open-GOP HEVC and MPEG-2 footage).
    ///
    /// A keyframe whose late-decoding predecessors are *not* the contiguous run just
    /// before it also gets `nil`: the `K − count` arithmetic would not match what the
    /// muxer keeps, so it is no boundary at all (never seen in a real stream — leading
    /// pictures sit between their keyframe and the previous GOP by construction).
    static func leadingPictureCounts(keyframeFlags: [Bool], dts: [Double]) -> [Int?] {
        // prefixMaxDTS[i] = the largest DTS among frames presented at/before i.
        var prefixMaxDTS = dts
        for i in dts.indices.dropFirst() {
            prefixMaxDTS[i] = max(prefixMaxDTS[i - 1], dts[i])
        }
        var counts = Array<Int?>(repeating: nil, count: keyframeFlags.count)
        for i in keyframeFlags.indices where keyframeFlags[i] {
            var j = i - 1
            while j >= 0, dts[j] > dts[i] { j -= 1 }
            // Everything before the contiguous run must decode before the keyframe,
            // or the cut would strand more frames than the count claims.
            if j < 0 || prefixMaxDTS[j] < dts[i] { counts[i] = i - 1 - j }
        }
        return counts
    }
}
