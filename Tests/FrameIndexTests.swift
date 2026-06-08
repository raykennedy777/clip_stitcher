import Testing
@testable import VidConform

/// Exercises the keyframe lookup that keyframe-aligned cuts (export Milestone 1)
/// will depend on: the nearest keyframe at or before a given frame is the safe
/// seek anchor / stream-copy boundary.
struct FrameIndexTests {
    /// frames: 0(K) 1 2 3(K) 4 5
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
}

/// Exercises snapping a requested in/out frame to the nearest *clean cut point* —
/// a closed-GOP keyframe safe for a pure stream-copy cut (ADR-0008). Milestone 1
/// only ever cuts at clean cut points, so a user's chosen frame is snapped to the
/// nearest one.
struct CleanCutSnapTests {
    /// 10 frames; clean cut points at frames 2 and 8.
    private let index = FrameIndex(
        pts: Array(stride(from: 0.0, through: 0.36, by: 0.04)),
        keyframeFlags:  [true, false, true, false, false, false, false, false, true, false],
        cleanCutFlags: [false, false, true, false, false, false, false, false, true, false]
    )

    @Test func snapsToTheNearerOfTwoCleanCutPoints() {
        #expect(index.nearestCleanCutPoint(to: 3) == 2)  // 1 frame away vs 5 away
        #expect(index.nearestCleanCutPoint(to: 6) == 8)  // 2 frames away vs 4 away
    }

    /// The segment-muxer cut time must sit *just below* the cut frame's PTS — the
    /// midpoint between it and the preceding frame — so ffmpeg's `>=` comparison
    /// lands on the intended frame rather than the next keyframe (ADR-0008).
    @Test func segmentTimeIsTheMidpointBeforeTheCutFrame() {
        // pts spacing 0.04: frame 2 = 0.08, frame 1 = 0.04 -> midpoint 0.06
        #expect(abs(index.segmentTime(forCutAt: 2) - 0.06) < 1e-9)
        // frame 8 = 0.32, frame 7 = 0.28 -> midpoint 0.30
        #expect(abs(index.segmentTime(forCutAt: 8) - 0.30) < 1e-9)
    }
}
