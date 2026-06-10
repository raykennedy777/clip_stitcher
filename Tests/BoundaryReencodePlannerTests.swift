import Testing
@testable import VidConform

/// Exercises the Milestone 2 planner (ADR-0009): a kept range becomes an ordered list
/// of logical segments tagged *copy* (stream-copy a keyframe-bounded span) or
/// *re-encode* (the partial GOPs at the head/tail), expressed purely as presentation
/// frame ranges so a CLI or a future libav backend can execute the same plan.
///
/// Boundary rules are asymmetric (#16): a copy may START only at a leading-picture-free
/// keyframe (count 0 — the strict rule), but may END at *any* counted keyframe `K`,
/// at presentation index `K − n_leading`: the segment-muxer cut before `K` sends its
/// leading pictures into the discarded segment.
struct BoundaryReencodePlannerTests {
    /// Builds leading-picture counts of `count` frames: 0 at the given clean boundaries
    /// (closed-GOP keyframes), plus any explicit open-GOP entries, nil elsewhere.
    private func counts(count: Int, boundaries: [Int], open: [Int: Int] = [:]) -> [Int?] {
        var c = Array<Int?>(repeating: nil, count: count)
        for b in boundaries { c[b] = 0 }
        for (k, n) in open { c[k] = n }
        return c
    }

    /// The canonical between-keyframes cut: re-encode the partial head, copy the
    /// keyframe-bounded middle, re-encode the partial tail — the recipe validated in the
    /// shell (head 7f, mid 250f, tail 8f). On clean boundaries the out-cut anchors at
    /// the copy range's end, exactly the pre-#16 behavior.
    @Test func reEncodesHeadAndTailAroundACopiedMiddle() {
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750, 1000]),
            frameCount: 1083, inFrame: 243, outFrame: 507)
        #expect(plan == [
            PlannedSegment(kind: .reEncode, range: 243..<250),
            PlannedSegment(kind: .copy,     range: 250..<500, outCutKeyframe: 500),
            PlannedSegment(kind: .reEncode, range: 500..<508),
        ])
    }

    /// A range that already starts and ends on copy-safe boundaries is a pure stream
    /// copy — no re-encode at all (M2 is never worse than M1 on boundary-aligned cuts).
    @Test func boundaryAlignedRangeIsPureCopy() {
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750]),
            frameCount: 1083, inFrame: 250, outFrame: 499)
        #expect(plan == [PlannedSegment(kind: .copy, range: 250..<500, outCutKeyframe: 500)])
    }

    /// A nil in/out means the clip boundary: copy from the file start / to the file end
    /// with no cut and no re-encode at that end.
    @Test func clipBoundariesCopyWithoutReEncoding() {
        let c = counts(count: 1083, boundaries: [0, 250, 500, 750])
        #expect(BoundaryReencodePlanner.plan(leadingCounts: c, frameCount: 1083, inFrame: nil, outFrame: nil)
                == [PlannedSegment(kind: .copy, range: 0..<1083)])
        #expect(BoundaryReencodePlanner.plan(leadingCounts: c, frameCount: 1083, inFrame: nil, outFrame: 507)
                == [PlannedSegment(kind: .copy, range: 0..<500, outCutKeyframe: 500),
                    PlannedSegment(kind: .reEncode, range: 500..<508)])
        #expect(BoundaryReencodePlanner.plan(leadingCounts: c, frameCount: 1083, inFrame: 243, outFrame: nil)
                == [PlannedSegment(kind: .reEncode, range: 243..<250),
                    PlannedSegment(kind: .copy, range: 250..<1083)])
    }

    /// When clean points are too sparse to bound a copy span (no copy-safe boundary in
    /// range, or only one), the whole kept range is re-encoded — correct, just costlier
    /// (ADR-0009: open-GOP degenerates toward full re-encode where clean points are rare).
    @Test func fullReEncodeWhenNoCopySpanFits() {
        // No boundary inside the range.
        #expect(BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 1000]),
            frameCount: 1083, inFrame: 200, outFrame: 300)
            == [PlannedSegment(kind: .reEncode, range: 200..<301)])
        // Exactly one boundary inside — can't bound a span.
        #expect(BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500]),
            frameCount: 1083, inFrame: 240, outFrame: 260)
            == [PlannedSegment(kind: .reEncode, range: 240..<261)])
    }

    /// Whatever the split, the segments are contiguous and cover exactly the kept range.
    @Test func segmentsContiguouslyCoverTheKeptRange() {
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750, 1000]),
            frameCount: 1083, inFrame: 243, outFrame: 507)
        #expect(plan.first?.range.lowerBound == 243)
        #expect(plan.last?.range.upperBound == 508)
        for (a, b) in zip(plan, plan.dropFirst()) {
            #expect(a.range.upperBound == b.range.lowerBound)
        }
        #expect(plan.reduce(0) { $0 + $1.range.count } == 508 - 243)
    }

    // MARK: asymmetric boundaries (#16)

    /// On open-GOP footage (every keyframe a CRA with leading pictures, the 2026 HEVC
    /// shape) a copy span may still END at any keyframe: the copy keeps
    /// `[start, K − n_leading)` and the tail re-encode covers the leading-picture slots
    /// and the rest — where pre-#16 the whole kept range re-encoded.
    @Test func openGopKeyframeEndsTheCopyAtKeyframeMinusLeading() {
        let c = counts(count: 1300, boundaries: [0],
                       open: [250: 3, 500: 3, 750: 3, 1000: 3, 1250: 3])
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1300, inFrame: nil, outFrame: 1200)
        #expect(plan == [
            PlannedSegment(kind: .copy, range: 0..<997, outCutKeyframe: 1000),
            PlannedSegment(kind: .reEncode, range: 997..<1201),
        ])
    }

    /// The strict rule survives on the start side: an open keyframe can END a span but
    /// never START one (its leading pictures would be orphaned at the seam), so a kept
    /// range with only open keyframes inside still re-encodes fully.
    @Test func openGopKeyframesCannotStartACopy() {
        let c = counts(count: 1300, boundaries: [0], open: [250: 2, 500: 2, 750: 2])
        #expect(BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1300, inFrame: 100, outFrame: 900)
            == [PlannedSegment(kind: .reEncode, range: 100..<901)])
    }

    /// The cut keyframe may sit beyond the kept range: with the out-point inside the
    /// keyframe's leading-picture slots, the copy still legally ends at `K − n_leading`
    /// and only the slots up to the out-point re-encode.
    @Test func endKeyframeMayLieBeyondTheOutPoint() {
        let c = counts(count: 1300, boundaries: [0], open: [1000: 4])
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1300, inFrame: nil, outFrame: 996)
        #expect(plan == [
            PlannedSegment(kind: .copy, range: 0..<996, outCutKeyframe: 1000),
            PlannedSegment(kind: .reEncode, range: 996..<997),
        ])
    }

    /// An out-point landing exactly on `K − n_leading` needs no tail re-encode at all:
    /// the cut alone produces the kept range.
    @Test func pureCopyWhenTheOutPointLandsExactlyBeforeTheLeadingPictures() {
        let c = counts(count: 1300, boundaries: [0], open: [1000: 4])
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1300, inFrame: nil, outFrame: 995)
        #expect(plan == [PlannedSegment(kind: .copy, range: 0..<996, outCutKeyframe: 1000)])
    }
}
