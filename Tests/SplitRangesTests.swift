import Foundation
import Testing
@testable import VidConform

/// Split-point arithmetic (issue #20, ADR-0017): a split at frame N starts the
/// range after it, only splits strictly inside the selection range (in < N ≤ out)
/// are live, and the divided ranges keep the original's open boundaries.
struct SplitRangesTests {
    @Test func noSplitsYieldTheSelectionRangeUnchanged() {
        let ranges = SplitRanges.ranges(splits: [], inPoint: 10, outPoint: 90, lastFrame: 99)
        #expect(ranges == [SplitRanges.Range(inPoint: 10, outPoint: 90)])
    }

    @Test func openBoundariesStayOpen() {
        let ranges = SplitRanges.ranges(splits: [50], inPoint: nil, outPoint: nil, lastFrame: 99)
        #expect(ranges == [
            SplitRanges.Range(inPoint: nil, outPoint: 49),
            SplitRanges.Range(inPoint: 50, outPoint: nil),
        ])
    }

    @Test func theSplitFrameStartsTheFollowingRange() {
        let ranges = SplitRanges.ranges(splits: [50], inPoint: 10, outPoint: 90, lastFrame: 99)
        #expect(ranges == [
            SplitRanges.Range(inPoint: 10, outPoint: 49),
            SplitRanges.Range(inPoint: 50, outPoint: 90),
        ])
    }

    @Test func multipleSplitsDivideInFrameOrder() {
        let ranges = SplitRanges.ranges(splits: [70, 30], inPoint: 10, outPoint: 90, lastFrame: 99)
        #expect(ranges == [
            SplitRanges.Range(inPoint: 10, outPoint: 29),
            SplitRanges.Range(inPoint: 30, outPoint: 69),
            SplitRanges.Range(inPoint: 70, outPoint: 90),
        ])
    }

    @Test func splitsOutsideTheSelectionRangeAreInert() {
        // 5 is before the in point, 10 == in (empty left range), 95 is past out.
        let ranges = SplitRanges.ranges(splits: [5, 10, 50, 95], inPoint: 10, outPoint: 90, lastFrame: 99)
        #expect(ranges == [
            SplitRanges.Range(inPoint: 10, outPoint: 49),
            SplitRanges.Range(inPoint: 50, outPoint: 90),
        ])
    }

    @Test func aSplitAtTheOutPointYieldsASingleFrameRange() {
        let ranges = SplitRanges.ranges(splits: [90], inPoint: 10, outPoint: 90, lastFrame: 99)
        #expect(ranges == [
            SplitRanges.Range(inPoint: 10, outPoint: 89),
            SplitRanges.Range(inPoint: 90, outPoint: 90),
        ])
    }

    @Test func liveRuleIsStrictlyInsideTheSelectionRange() {
        #expect(!SplitRanges.isLive(10, inPoint: 10, outPoint: 90, lastFrame: 99))
        #expect(SplitRanges.isLive(11, inPoint: 10, outPoint: 90, lastFrame: 99))
        #expect(SplitRanges.isLive(90, inPoint: 10, outPoint: 90, lastFrame: 99))
        #expect(!SplitRanges.isLive(91, inPoint: 10, outPoint: 90, lastFrame: 99))
        // Open boundaries: in nil acts as 0, out nil as the last frame.
        #expect(!SplitRanges.isLive(0, inPoint: nil, outPoint: nil, lastFrame: 99))
        #expect(SplitRanges.isLive(99, inPoint: nil, outPoint: nil, lastFrame: 99))
        #expect(!SplitRanges.isLive(100, inPoint: nil, outPoint: nil, lastFrame: 99))
    }
}
