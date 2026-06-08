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
