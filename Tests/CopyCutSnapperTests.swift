import Testing
@testable import ClipStitcher

struct CopyCutSnapperTests {
    let counts: [Int?] = [0, nil, nil, nil, 2, nil, nil, nil,
                          0, nil, nil, nil, 2, nil, nil, nil]

    @Test func inPointAlreadyCopySafeStaysPut() {
        #expect(CopyCutSnapper.snapInPoint(8, leadingCounts: counts) == 8)
        #expect(CopyCutSnapper.snapInPoint(0, leadingCounts: counts) == 0)
    }

    @Test func inPointSnapsToNearestCopySafeKeyframe() {
        #expect(CopyCutSnapper.snapInPoint(2, leadingCounts: counts) == 0)
        #expect(CopyCutSnapper.snapInPoint(6, leadingCounts: counts) == 8)
    }

    @Test func inPointSkipsOpenKeyframes() {
        #expect(CopyCutSnapper.snapInPoint(5, leadingCounts: counts) == 8)
    }

    @Test func inPointTiePrefersEarlierToKeepTheRequestedFrame() {
        #expect(CopyCutSnapper.snapInPoint(4, leadingCounts: counts) == 0)
    }

    @Test func inPointAtLastFrameSnapsBackward() {
        #expect(CopyCutSnapper.snapInPoint(15, leadingCounts: counts) == 8)
    }

    @Test func inPointIsNilWhenNoCopySafeKeyframeExists() {
        let allOpen: [Int?] = [nil, nil, 2, nil, nil]
        #expect(CopyCutSnapper.snapInPoint(3, leadingCounts: allOpen) == nil)
    }

    @Test func outPointAlreadyValidStaysPut() {
        #expect(CopyCutSnapper.snapOutPoint(7, leadingCounts: counts) == 7)
        #expect(CopyCutSnapper.snapOutPoint(1, leadingCounts: counts) == 1)
    }

    @Test func outPointSnapsToKeyframeMinusLeadingCount() {
        #expect(CopyCutSnapper.snapOutPoint(3, leadingCounts: counts) == 1)
        #expect(CopyCutSnapper.snapOutPoint(5, leadingCounts: counts) == 7)
    }

    @Test func outPointTiePrefersLaterToKeepTheRequestedFrame() {
        #expect(CopyCutSnapper.snapOutPoint(8, leadingCounts: counts) == 9)
    }

    @Test func outPointAtFirstFrameSnapsForward() {
        #expect(CopyCutSnapper.snapOutPoint(0, leadingCounts: counts) == 1)
    }

    @Test func outPointIsNilWhenOnlyTheFileStartKeyframeIsCounted() {
        let single: [Int?] = [0, nil, nil, nil]
        #expect(CopyCutSnapper.snapOutPoint(2, leadingCounts: single) == nil)
    }

    @Test func emptyIndexReturnsNilForBothPoints() {
        #expect(CopyCutSnapper.snapInPoint(0, leadingCounts: []) == nil)
        #expect(CopyCutSnapper.snapOutPoint(0, leadingCounts: []) == nil)
    }

    @Test func agreesWithCopySafeBoundaryDetectorOnAnOpenGop() {
        let detected = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: [true, false, false, false, true,  false],
            dts:           [0.00, 0.04, 0.12,  0.16,  0.08,  0.20]
        )
        #expect(CopyCutSnapper.snapInPoint(3, leadingCounts: detected) == 0)
        #expect(CopyCutSnapper.snapOutPoint(3, leadingCounts: detected) == 1)
    }

    @Test func snappedCutMakesThePlannerCopyOnly() {
        let inPoint = CopyCutSnapper.snapInPoint(2, leadingCounts: counts)
        let outPoint = CopyCutSnapper.snapOutPoint(5, leadingCounts: counts)
        #expect(inPoint == 0)
        #expect(outPoint == 7)

        let snapped = BoundaryReencodePlanner.plan(
            leadingCounts: counts, frameCount: counts.count,
            inFrame: inPoint, outFrame: outPoint)
        #expect(snapped == [
            PlannedSegment(kind: .copy, range: 0..<8, outCutKeyframe: 8)
        ])

        let raw = BoundaryReencodePlanner.plan(
            leadingCounts: counts, frameCount: counts.count, inFrame: 2, outFrame: 5)
        #expect(raw.contains { $0.kind == .reEncode })
    }

    @Test func snappedMidFileCutIsAlsoCopyOnly() {
        let inPoint = CopyCutSnapper.snapInPoint(8, leadingCounts: counts)
        let outPoint = CopyCutSnapper.snapOutPoint(10, leadingCounts: counts)
        #expect(inPoint == 8)
        #expect(outPoint == 9)

        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts, frameCount: counts.count,
            inFrame: inPoint, outFrame: outPoint)
        #expect(plan == [
            PlannedSegment(kind: .copy, range: 8..<10, outCutKeyframe: 12)
        ])
    }
}
