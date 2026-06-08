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
}

/// Turns a clip's kept range into a Milestone 2 segment plan (ADR-0009). Pure logic over
/// the copy-safe boundaries (`CopySafeBoundaryDetector`), so it is fully unit-testable
/// without ffmpeg.
///
/// `inFrame`/`outFrame` are exact presentation frames the user chose — M2 does **not**
/// snap them to clean points (that is the whole advantage over M1); it only re-encodes
/// the partial GOPs needed to reach the nearest copy-safe boundaries. A `nil` in/out is
/// the clip boundary (file start / end): that end is copied with no cut and no re-encode,
/// so a whole-clip keep is a pure copy, never worse than M1.
enum BoundaryReencodePlanner {
    static func plan(
        copySafeFlags: [Bool], frameCount: Int, inFrame: Int?, outFrame: Int?
    ) -> [PlannedSegment] {
        let inStart = inFrame ?? 0
        let outEx = outFrame.map { $0 + 1 } ?? frameCount
        guard outEx > inStart else { return [] }

        let boundaries = copySafeFlags.indices.filter { copySafeFlags[$0] }

        // Where a frame-exact stream copy can begin: the file start needs no in-cut;
        // otherwise the first copy-safe boundary at/after the in-point.
        let copyStart: Int? = inFrame == nil
            ? inStart
            : boundaries.first { $0 >= inStart && $0 < outEx }
        // Where it can end: the file end needs no out-cut; otherwise the last copy-safe
        // boundary beyond the copy start and at/before the out-point.
        let copyEnd: Int? = {
            guard let start = copyStart else { return nil }
            if outFrame == nil { return frameCount }
            return boundaries.last { $0 > start && $0 <= outEx }
        }()

        guard let start = copyStart, let end = copyEnd, end > start else {
            // No copy span fits — re-encode the whole kept range (sparse clean points).
            return [PlannedSegment(kind: .reEncode, range: inStart..<outEx)]
        }

        var segments: [PlannedSegment] = []
        if start > inStart { segments.append(PlannedSegment(kind: .reEncode, range: inStart..<start)) }
        segments.append(PlannedSegment(kind: .copy, range: start..<end))
        if end < outEx { segments.append(PlannedSegment(kind: .reEncode, range: end..<outEx)) }
        return segments
    }
}
