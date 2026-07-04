import Foundation

/// Snaps a requested cut point to the nearest boundary where a **pure stream copy** is
/// valid — the keyframe-aligned copy-only cutting for field-coded (PAFF) clips (#96),
/// where boundary re-encoding is off the table (ADR-0022). Pure frame-number math over
/// the per-frame leading-picture counts, kept out of the model so the rules are
/// testable without a clip (the `SplitRanges` pattern).
///
/// Both points are **inclusive presentation-frame indices**, matching
/// `CutEditorModel.inPoint`/`outPoint` and `BoundaryReencodePlanner.plan`'s
/// `inFrame`/`outFrame`. The rules are the planner's asymmetric boundary rules (#16),
/// consumed from `CopySafeBoundaryDetector.leadingPictureCounts`, so a snapped in/out
/// pair makes the planner's partial-GOP `.reEncode` edges vanish by construction:
///
/// - An **in-point** (first kept frame) may sit only on a leading-picture-free
///   keyframe (count 0) — a copy may START nowhere else, or the seam would orphan the
///   keyframe's leading pictures.
/// - An **out-point** (last kept frame) may sit at `k − count − 1` for *any* counted
///   keyframe `k`: the segment-muxer cut just before `k`'s DTS keeps exactly the
///   frames through `k − count − 1` and drops `k`'s leading pictures on the discarded
///   side, so even an open-GOP keyframe legally ENDS a copy. The file-start keyframe
///   yields no candidate (a copy cannot end before frame 0).
///
/// "Nearest" is by frame distance; an equidistant tie goes to the candidate that keeps
/// the requested frame **inside** the kept range (earlier for in, later for out), so a
/// snap never silently drops the frame the user parked on when it doesn't have to.
enum CopyCutSnapper {
    /// The nearest valid in-point for `requested`, or `nil` when the index contains no
    /// leading-picture-free keyframe at all (then no copy start exists anywhere and
    /// the caller must not place an in-point).
    static func snapInPoint(_ requested: Int, leadingCounts: [Int?]) -> Int? {
        nearest(to: requested,
                among: leadingCounts.indices.filter { leadingCounts[$0] == 0 },
                keepsRequestedFrameWhen: <)
    }

    /// The nearest valid out-point for `requested`, or `nil` when no counted keyframe
    /// yields one (empty index, or only the file-start keyframe — then only the open
    /// clip end, `outPoint = nil` copying to EOF, keeps any of the stream).
    static func snapOutPoint(_ requested: Int, leadingCounts: [Int?]) -> Int? {
        let candidates = leadingCounts.indices.compactMap { k -> Int? in
            guard let count = leadingCounts[k] else { return nil }
            let lastKept = k - count - 1
            return lastKept >= 0 ? lastKept : nil
        }
        return nearest(to: requested, among: candidates, keepsRequestedFrameWhen: >)
    }

    /// The candidate nearest to `requested`; equidistant ties go to the side that
    /// keeps the requested frame in the kept range (`<` for in-points, `>` for outs).
    private static func nearest(
        to requested: Int, among candidates: [Int],
        keepsRequestedFrameWhen keeps: (Int, Int) -> Bool
    ) -> Int? {
        candidates.min { a, b in
            let (da, db) = (abs(a - requested), abs(b - requested))
            return da != db ? da < db : keeps(a, b)
        }
    }
}
