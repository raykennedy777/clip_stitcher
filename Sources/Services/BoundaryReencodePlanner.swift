import Foundation

/// One logical piece of a Milestone 2 export: a contiguous presentation-frame range
/// produced either by a stream **copy** (a keyframe-bounded span, frame-exact and cheap)
/// or by a **re-encode** (the partial GOPs at the head/tail of the kept range).
///
/// The plan is a list of these in output order, kept deliberately separate from how they
/// are executed: the CLI backend maps a copy to a segment-muxer cut and a re-encode to a
/// frame-selected libx26x/mpeg2 pass, while a future libav backend (Milestone 2b) can
/// consume the same plan and add a third *re-encode-leading-pictures-only* kind without
/// reshaping it (ADR-0009).
struct PlannedSegment: Equatable {
    enum Kind { case copy, reEncode }
    var kind: Kind
    /// Presentation frames covered, half-open `[lowerBound, upperBound)`.
    var range: Range<Int>
    /// For a copy segment trimmed at its tail: the keyframe anchoring the segment-muxer
    /// out-cut. The cut lands just before this keyframe's DTS, which keeps exactly
    /// `range` — the keyframe's leading pictures (presented before it, decoded after it)
    /// fall into the *discarded* segment, so `range.upperBound` is the keyframe's index
    /// minus its leading-picture count (#16). On clean boundaries the two coincide.
    /// `nil` on a copy that runs to the clip end, and on re-encodes.
    var outCutKeyframe: Int? = nil
}

/// Turns a clip's kept range into a Milestone 2 segment plan (ADR-0009). Pure logic over
/// the per-keyframe leading-picture counts (`CopySafeBoundaryDetector`), so it is fully
/// unit-testable without ffmpeg.
///
/// `inFrame`/`outFrame` are exact presentation frames the user chose — M2 does **not**
/// snap them to clean points (that is the whole advantage over M1); it only re-encodes
/// the partial GOPs needed to reach the nearest legal copy boundaries. A `nil` in/out is
/// the clip boundary (file start / end): that end is copied with no cut and no re-encode,
/// so a whole-clip keep is a pure copy, never worse than M1.
///
/// The boundary rules are asymmetric (#16): a copy may START only at a
/// leading-picture-free keyframe (count 0 — anything looser would orphan the leading
/// pictures at the re-encode→copy seam), but may END at *any* counted keyframe `K`, at
/// presentation index `K − n_leading`: the segment-muxer cut just before `K` sends its
/// leading pictures into the discarded segment, no bitstream surgery needed. On
/// closed-GOP footage every count is 0 and both rules collapse to the pre-#16 behavior.
enum BoundaryReencodePlanner {
    static func plan(
        leadingCounts: [Int?], frameCount: Int, inFrame: Int?, outFrame: Int?
    ) -> [PlannedSegment] {
        let inStart = inFrame ?? 0
        let outEx = outFrame.map { $0 + 1 } ?? frameCount
        guard outEx > inStart else { return [] }

        // Where a frame-exact stream copy can begin: the file start needs no in-cut;
        // otherwise the first leading-picture-free keyframe at/after the in-point.
        let copyStart: Int? = inFrame == nil
            ? inStart
            : leadingCounts.indices.first {
                leadingCounts[$0] == 0 && $0 >= inStart && $0 < outEx
            }

        // Where it can end: the file end needs no out-cut. Otherwise the keyframe whose
        // cut-before-it end (`K − n_leading`) reaches deepest into the kept range — the
        // keyframe itself may sit beyond the out-point when only its leading-picture
        // slots are trimmed off.
        let copyEnd: (end: Int, cutKeyframe: Int?)? = {
            guard let start = copyStart else { return nil }
            if outFrame == nil { return (frameCount, nil) }
            var best: (end: Int, cutKeyframe: Int?)?
            for k in leadingCounts.indices {
                guard let n = leadingCounts[k] else { continue }
                let end = k - n
                if end > (best?.end ?? start), end <= outEx { best = (end, k) }
            }
            return best
        }()

        guard let start = copyStart, let (end, cutKeyframe) = copyEnd, end > start else {
            // No copy span fits — re-encode the whole kept range (sparse clean points).
            return [PlannedSegment(kind: .reEncode, range: inStart..<outEx)]
        }

        var segments: [PlannedSegment] = []
        if start > inStart { segments.append(PlannedSegment(kind: .reEncode, range: inStart..<start)) }
        segments.append(PlannedSegment(kind: .copy, range: start..<end, outCutKeyframe: cutKeyframe))
        if end < outEx { segments.append(PlannedSegment(kind: .reEncode, range: end..<outEx)) }
        return segments
    }
}
