import Testing
@testable import VidConform

/// The Milestone 1 export planner: given a clip's frame index and chosen in/out
/// frames, produce a keyframe-aligned segment plan whose cuts land only on clean
/// cut points (ADR-0008).
struct ExportPlannerTests {
    /// 10 frames; clean cut points at frames 2 and 8.
    private let index = FrameIndex(
        pts: Array(stride(from: 0.0, through: 0.36, by: 0.04)),
        keyframeFlags:  [true, false, true, false, false, false, false, false, true, false],
        cleanCutFlags: [false, false, true, false, false, false, false, false, true, false]
    )

    @Test func snapsInAndOutToCleanCutPoints() {
        let plan = ExportPlanner.plan(index: index, inFrame: 3, outFrame: 6)
        #expect(plan.inFrame == 2)
        #expect(plan.outFrame == 8)
    }

    @Test func flagsWhichEndsWereMovedBySnapping() {
        // in 3 -> 2 (moved); out 8 is already a clean cut point (not moved)
        let plan = ExportPlanner.plan(index: index, inFrame: 3, outFrame: 8)
        #expect(plan.inMoved == true)
        #expect(plan.outMoved == false)
    }

    @Test func carriesSegmentMuxerCutTimesForTheSnappedFrames() {
        let plan = ExportPlanner.plan(index: index, inFrame: 3, outFrame: 8)
        // in snaps to frame 2 -> midpoint(0.04, 0.08) = 0.06
        #expect(abs(plan.inSegmentTime - 0.06) < 1e-9)
        // out is frame 8 -> midpoint(0.28, 0.32) = 0.30
        #expect(abs(plan.outSegmentTime - 0.30) < 1e-9)
    }
}
