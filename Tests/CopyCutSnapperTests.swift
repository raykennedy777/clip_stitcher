import Testing
@testable import ClipStitcher

/// Exercises the copy-only cut snapping for field-coded (PAFF) clips (#96): a requested
/// in-point snaps to the nearest leading-picture-free keyframe (the only legal copy
/// START), a requested out-point to `k − count − 1` for the nearest counted keyframe
/// `k` (any counted keyframe legally ENDS a copy — its leading pictures fall on the
/// discarded side). Points are inclusive presentation-frame indices, matching
/// `CutEditorModel.inPoint`/`outPoint` and the planner's `inFrame`/`outFrame`.
struct CopyCutSnapperTests {
    /// A 16-frame open-GOP shape: copy-safe keyframes at 0 and 8 (count 0), open
    /// keyframes at 4 and 12 (count 2, leading pictures in the two slots before them).
    /// In-point candidates: {0, 8}. Out-point candidates: {1, 7, 9} — keyframe 4 ends a
    /// copy at 4−2−1 = 1, keyframe 8 at 7, keyframe 12 at 9; keyframe 0 ends nothing
    /// (a copy cannot end before frame 0).
    let counts: [Int?] = [0, nil, nil, nil, 2, nil, nil, nil,
                          0, nil, nil, nil, 2, nil, nil, nil]

    // MARK: In-point (copy START)

    /// A request already on a copy-safe keyframe does not move — including frame 0.
    @Test func inPointAlreadyCopySafeStaysPut() {
        #expect(CopyCutSnapper.snapInPoint(8, leadingCounts: counts) == 8)
        #expect(CopyCutSnapper.snapInPoint(0, leadingCounts: counts) == 0)
    }

    /// Requests between candidates snap to the nearer copy-safe keyframe, in either
    /// direction.
    @Test func inPointSnapsToNearestCopySafeKeyframe() {
        #expect(CopyCutSnapper.snapInPoint(2, leadingCounts: counts) == 0)
        #expect(CopyCutSnapper.snapInPoint(6, leadingCounts: counts) == 8)
    }

    /// An open keyframe (count > 0) is never an in-point, however close: starting a
    /// copy there would orphan its leading pictures. Frame 5 sits right next to the
    /// open keyframe at 4 but snaps past it to the copy-safe keyframe at 8.
    @Test func inPointSkipsOpenKeyframes() {
        #expect(CopyCutSnapper.snapInPoint(5, leadingCounts: counts) == 8)
    }

    /// Equidistant candidates: the earlier one wins, so the frame the user parked on
    /// stays inside the kept range.
    @Test func inPointTiePrefersEarlierToKeepTheRequestedFrame() {
        #expect(CopyCutSnapper.snapInPoint(4, leadingCounts: counts) == 0)
    }

    /// A request at the last frame still finds the nearest candidate behind it.
    @Test func inPointAtLastFrameSnapsBackward() {
        #expect(CopyCutSnapper.snapInPoint(15, leadingCounts: counts) == 8)
    }

    /// A stream with no leading-picture-free keyframe at all (every keyframe open)
    /// has no legal copy start: nil, and the caller must not place the in-point.
    @Test func inPointIsNilWhenNoCopySafeKeyframeExists() {
        let allOpen: [Int?] = [nil, nil, 2, nil, nil]
        #expect(CopyCutSnapper.snapInPoint(3, leadingCounts: allOpen) == nil)
    }

    // MARK: Out-point (copy END)

    /// A request already on a valid copy end does not move — whether the ending
    /// keyframe is copy-safe (7, before keyframe 8) or open (1, before keyframe 4).
    @Test func outPointAlreadyValidStaysPut() {
        #expect(CopyCutSnapper.snapOutPoint(7, leadingCounts: counts) == 7)
        #expect(CopyCutSnapper.snapOutPoint(1, leadingCounts: counts) == 1)
    }

    /// Requests between candidates snap to the nearer `k − count − 1`, in either
    /// direction — the open keyframe at 4 ends a copy at frame 1, two slots early,
    /// because frames 2–3 are its leading pictures and fall on the discarded side.
    @Test func outPointSnapsToKeyframeMinusLeadingCount() {
        #expect(CopyCutSnapper.snapOutPoint(3, leadingCounts: counts) == 1)
        #expect(CopyCutSnapper.snapOutPoint(5, leadingCounts: counts) == 7)
    }

    /// Equidistant candidates: the later one wins, so the frame the user parked on
    /// stays inside the kept range (out is the *last kept* frame).
    @Test func outPointTiePrefersLaterToKeepTheRequestedFrame() {
        #expect(CopyCutSnapper.snapOutPoint(8, leadingCounts: counts) == 9)
    }

    /// A request at frame 0 still finds the nearest candidate ahead of it.
    @Test func outPointAtFirstFrameSnapsForward() {
        #expect(CopyCutSnapper.snapOutPoint(0, leadingCounts: counts) == 1)
    }

    /// The file-start keyframe ends nothing (its cut point would be frame −1), so a
    /// stream whose only counted keyframe is frame 0 has no legal out-point: nil —
    /// only the open clip end (`outPoint = nil`, copy to EOF) keeps such a stream.
    @Test func outPointIsNilWhenOnlyTheFileStartKeyframeIsCounted() {
        let single: [Int?] = [0, nil, nil, nil]
        #expect(CopyCutSnapper.snapOutPoint(2, leadingCounts: single) == nil)
    }

    /// An empty index snaps nowhere.
    @Test func emptyIndexReturnsNilForBothPoints() {
        #expect(CopyCutSnapper.snapInPoint(0, leadingCounts: []) == nil)
        #expect(CopyCutSnapper.snapOutPoint(0, leadingCounts: []) == nil)
    }

    // MARK: Agreement with the detector and the planner

    /// End to end from the raw index: the counts come from
    /// `CopySafeBoundaryDetector.leadingPictureCounts` (the open-GOP shape from its own
    /// tests — keyframe at 4 with two leading pictures) and the snapper lands on the
    /// boundaries its doc comments promise: in → the count-0 keyframe, out → `4 − 2 − 1`.
    @Test func agreesWithCopySafeBoundaryDetectorOnAnOpenGop() {
        let detected = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: [true, false, false, false, true,  false],
            dts:           [0.00, 0.04, 0.12,  0.16,  0.08,  0.20]
        )
        #expect(CopyCutSnapper.snapInPoint(3, leadingCounts: detected) == 0)
        #expect(CopyCutSnapper.snapOutPoint(3, leadingCounts: detected) == 1)
    }

    /// The point of snapping: a snapped in/out pair makes the planner's partial-GOP
    /// `.reEncode` edges vanish by construction — one pure copy segment, ending on the
    /// out-cut keyframe — where the raw request would have produced re-encodes.
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

    /// The same invariant away from the file start: in on the mid-file copy-safe
    /// keyframe, out ending just before the open keyframe at 12.
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
