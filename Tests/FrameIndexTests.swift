import Testing
@testable import ClipStitcher

struct FrameIndexTests {
    private let index = FrameIndex(
        pts: [0.0, 0.04, 0.08, 0.12, 0.16, 0.20],
        keyframeFlags: [true, false, false, true, false, false]
    )

    @Test func keyframeAtOrBeforeReturnsTheFrameItselfWhenItIsAKeyframe() {
        #expect(index.keyframeIndex(atOrBefore: 0) == 0)
        #expect(index.keyframeIndex(atOrBefore: 3) == 3)
    }

    @Test func keyframeAtOrBeforeWalksBackToTheNearestEarlierKeyframe() {
        #expect(index.keyframeIndex(atOrBefore: 2) == 0)
        #expect(index.keyframeIndex(atOrBefore: 5) == 3)
    }

    @Test func keyframeAtOrBeforeIsNilWhenNoEarlierKeyframeExists() {
        let headless = FrameIndex(pts: [0.0, 0.04, 0.08, 0.12],
                                  keyframeFlags: [false, false, true, false])
        #expect(headless.keyframeIndex(atOrBefore: 0) == nil)
        #expect(headless.keyframeIndex(atOrBefore: 1) == nil)
        #expect(headless.keyframeIndex(atOrBefore: 2) == 2)
        #expect(headless.keyframeIndex(atOrBefore: 3) == 2)
    }

    @Test func keyframeAtOrBeforeIsNilForAnEmptyIndex() {
        #expect(FrameIndex(pts: [], keyframeFlags: []).keyframeIndex(atOrBefore: 0) == nil)
    }

    @Test func keyframeAfterFindsTheNextLaterKeyframe() {
        #expect(index.keyframeIndex(after: 0) == 3)
        #expect(index.keyframeIndex(after: 2) == 3)
    }

    @Test func keyframeAfterSkipsTheFrameItselfEvenWhenItIsAKeyframe() {
        #expect(index.keyframeIndex(after: 3) == nil)
    }

    @Test func keyframeAfterReturnsNilPastTheLastKeyframe() {
        #expect(index.keyframeIndex(after: 4) == nil)
        #expect(index.keyframeIndex(after: 5) == nil)
    }

    @Test func durationSpanIsTheLastMinusFirstPts() {
        #expect(index.durationSpan == 0.20)
        let offset = FrameIndex(pts: [10.0, 11.0, 13.0], keyframeFlags: [true, false, false])
        #expect(offset.durationSpan == 3.0)
    }

    @Test func durationSpanIsZeroForEmptyOrSingleFrame() {
        #expect(FrameIndex(pts: [], keyframeFlags: []).durationSpan == 0)
        #expect(FrameIndex(pts: [5.0], keyframeFlags: [true]).durationSpan == 0)
    }
}

struct SegmentTimeWithBFramesTests {
    private let index = FrameIndex(
        pts: [0.00, 0.04, 0.08, 0.12, 0.16, 0.20],
        dts: [0.00, 0.02, 0.04, 0.06, 0.08, 0.10],
        keyframeFlags: [true, false, false, true, false, false]
    )

    @Test func segmentTimeUsesDecodeTimeNotPresentationTime() {
        #expect(abs(index.segmentTime(forCutAt: 3) - 0.05) < 1e-9)
    }
}

struct SegmentTimeStartOffsetTests {
    private let index = FrameIndex(
        pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44],
        dts: [0.20, 0.22, 0.24, 0.26, 0.28, 0.30],
        keyframeFlags: [true, false, false, true, false, false]
    )

    @Test func segmentTimeSubtractsTheStreamStartTime() {
        #expect(abs(index.segmentTime(forCutAt: 3) - 0.01) < 1e-9)
    }

    @Test func segmentTimeForTheFirstDecodedFrameStaysAtOrBelowItsRelativeDTS() {
        let relativeDTS = index.dts[0] - index.pts[0]
        #expect(index.segmentTime(forCutAt: 0) <= relativeDTS + 1e-9)
    }
}

struct SegmentTimeBackToBackKeyframeTests {
    static func splitsExactlyAt(_ n: Int, _ index: FrameIndex) -> Bool {
        let cut = index.segmentTime(forCutAt: n) + (index.pts.first ?? 0)
        let earlier = index.keyframeFlags.indices.filter {
            index.keyframeFlags[$0] && index.dts[$0] < index.dts[n]
        }
        return index.pts[n] >= cut && earlier.allSatisfy { index.pts[$0] < cut }
    }

    @Test func aCutAfterAnAdjacentIFrameSplitsAtTheCutKeyframe() {
        let index = FrameIndex(
            pts: [0.00, 0.04, 0.08, 0.12, 0.16, 0.20, 0.24, 0.28],
            dts: [0.00, 0.04, -0.04, 0.08, 0.12, 0.20, 0.24, 0.16],
            keyframeFlags: [false, false, false, true, true, false, false, false])
        #expect(Self.splitsExactlyAt(4, index))
        #expect(abs(index.segmentTime(forCutAt: 4) - 0.14) < 1e-9)
    }

    @Test func aCutAfterAKeyframeAndOneBFrameSplitsAtTheCutKeyframe() {
        let index = FrameIndex(
            pts: [0.00, 0.04, 0.08, 0.12, 0.16, 0.20],
            dts: [0.00, -0.04, 0.04, 0.12, 0.16, 0.08],
            keyframeFlags: [false, true, true, false, false, false])
        #expect(Self.splitsExactlyAt(2, index))
        #expect(abs(index.segmentTime(forCutAt: 2) - 0.06) < 1e-9)
    }

    @Test func aSafeDTSMidpointIsUnchanged() {
        let index = FrameIndex(
            pts: [0.00, 0.04, 0.08, 0.12, 0.16, 0.20],
            dts: [0.00, 0.02, 0.04, 0.06, 0.08, 0.10],
            keyframeFlags: [true, false, false, true, false, false])
        #expect(Self.splitsExactlyAt(3, index))
        #expect(abs(index.segmentTime(forCutAt: 3) - 0.05) < 1e-9)
    }
}
