import Testing
@testable import VidConform

/// Exercises the Milestone 2 planner (ADR-0009): a kept range becomes an ordered list
/// of logical segments tagged *copy* (stream-copy a keyframe-bounded span) or
/// *re-encode* (the partial GOPs at the head/tail), expressed purely as presentation
/// frame ranges so a CLI or a future libav backend can execute the same plan.
struct BoundaryReencodePlannerTests {
    /// Builds copy-safe flags of `count` frames with boundaries at the given indices.
    private func flags(count: Int, boundaries: [Int]) -> [Bool] {
        var f = Array(repeating: false, count: count)
        for b in boundaries { f[b] = true }
        return f
    }

    /// The canonical between-keyframes cut: re-encode the partial head, copy the
    /// keyframe-bounded middle, re-encode the partial tail — the recipe validated in the
    /// shell (head 7f, mid 250f, tail 8f).
    @Test func reEncodesHeadAndTailAroundACopiedMiddle() {
        let plan = BoundaryReencodePlanner.plan(
            copySafeFlags: flags(count: 1083, boundaries: [0, 250, 500, 750, 1000]),
            frameCount: 1083, inFrame: 243, outFrame: 507)
        #expect(plan == [
            PlannedSegment(kind: .reEncode, range: 243..<250),
            PlannedSegment(kind: .copy,     range: 250..<500),
            PlannedSegment(kind: .reEncode, range: 500..<508),
        ])
    }

    /// A range that already starts and ends on copy-safe boundaries is a pure stream
    /// copy — no re-encode at all (M2 is never worse than M1 on boundary-aligned cuts).
    @Test func boundaryAlignedRangeIsPureCopy() {
        let plan = BoundaryReencodePlanner.plan(
            copySafeFlags: flags(count: 1083, boundaries: [0, 250, 500, 750]),
            frameCount: 1083, inFrame: 250, outFrame: 499)
        #expect(plan == [PlannedSegment(kind: .copy, range: 250..<500)])
    }

    /// A nil in/out means the clip boundary: copy from the file start / to the file end
    /// with no cut and no re-encode at that end.
    @Test func clipBoundariesCopyWithoutReEncoding() {
        let f = flags(count: 1083, boundaries: [0, 250, 500, 750])
        #expect(BoundaryReencodePlanner.plan(copySafeFlags: f, frameCount: 1083, inFrame: nil, outFrame: nil)
                == [PlannedSegment(kind: .copy, range: 0..<1083)])
        #expect(BoundaryReencodePlanner.plan(copySafeFlags: f, frameCount: 1083, inFrame: nil, outFrame: 507)
                == [PlannedSegment(kind: .copy, range: 0..<500),
                    PlannedSegment(kind: .reEncode, range: 500..<508)])
        #expect(BoundaryReencodePlanner.plan(copySafeFlags: f, frameCount: 1083, inFrame: 243, outFrame: nil)
                == [PlannedSegment(kind: .reEncode, range: 243..<250),
                    PlannedSegment(kind: .copy, range: 250..<1083)])
    }

    /// When clean points are too sparse to bound a copy span (no copy-safe boundary in
    /// range, or only one), the whole kept range is re-encoded — correct, just costlier
    /// (ADR-0009: open-GOP degenerates toward full re-encode where clean points are rare).
    @Test func fullReEncodeWhenNoCopySpanFits() {
        // No boundary inside the range.
        #expect(BoundaryReencodePlanner.plan(
            copySafeFlags: flags(count: 1083, boundaries: [0, 1000]),
            frameCount: 1083, inFrame: 200, outFrame: 300)
            == [PlannedSegment(kind: .reEncode, range: 200..<301)])
        // Exactly one boundary inside — can't bound a span.
        #expect(BoundaryReencodePlanner.plan(
            copySafeFlags: flags(count: 1083, boundaries: [0, 250, 500]),
            frameCount: 1083, inFrame: 240, outFrame: 260)
            == [PlannedSegment(kind: .reEncode, range: 240..<261)])
    }

    /// Whatever the split, the segments are contiguous and cover exactly the kept range.
    @Test func segmentsContiguouslyCoverTheKeptRange() {
        let plan = BoundaryReencodePlanner.plan(
            copySafeFlags: flags(count: 1083, boundaries: [0, 250, 500, 750, 1000]),
            frameCount: 1083, inFrame: 243, outFrame: 507)
        #expect(plan.first?.range.lowerBound == 243)
        #expect(plan.last?.range.upperBound == 508)
        for (a, b) in zip(plan, plan.dropFirst()) {
            #expect(a.range.upperBound == b.range.lowerBound)
        }
        #expect(plan.reduce(0) { $0 + $1.range.count } == 508 - 243)
    }
}
