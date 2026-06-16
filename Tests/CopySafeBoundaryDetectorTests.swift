import Testing
@testable import ClipStitcher

/// Exercises the *copy-safe boundary* test for Milestone 2's boundary re-encode
/// (ADR-0009): the keyframes a stream-copied middle may start/end on without dragging
/// in orphaned leading pictures at the re-encode→copy seam. It is the general
/// leading-picture-free test applied to **every** codec.
struct CopySafeBoundaryDetectorTests {
    /// Closed GOP (decode order == presentation order, DTS monotonic): every keyframe
    /// is copy-safe — nothing presented earlier decodes later.
    @Test func everyKeyframeIsCopySafeInAClosedGop() {
        let flags = CopySafeBoundaryDetector.copySafeFlags(
            keyframeFlags: [true, false, false, true, false],
            dts:           [0.00, 0.04, 0.08, 0.12, 0.16]
        )
        #expect(flags == [true, false, false, true, false])
    }

    /// An *open* keyframe with a leading picture is excluded. Presentation frame 2 is a
    /// keyframe decoding at 0.02, but presentation frame 1 (earlier on screen) decodes
    /// later at 0.04 — a leading picture — so a copied middle starting at frame 2 would
    /// orphan it. Frame 0 has nothing before it and stays copy-safe.
    @Test func anOpenKeyframeWithLeadingPicturesIsNotCopySafe() {
        let flags = CopySafeBoundaryDetector.copySafeFlags(
            keyframeFlags: [true, false, true,  false, false],
            dts:           [0.00, 0.04, 0.02,  0.06,  0.08]
        )
        #expect(flags == [true, false, false, false, false])
    }

    /// Closed GOP: every keyframe has zero leading pictures (the strict copy-safe case);
    /// non-keyframes carry no count.
    @Test func leadingCountsAreZeroAtClosedGopKeyframes() {
        let counts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: [true, false, false, true, false],
            dts:           [0.00, 0.04, 0.08, 0.12, 0.16]
        )
        #expect(counts == [0, nil, nil, 0, nil])
    }

    /// The open-GOP shape #16 exists for (a CRA with RASL pictures, or an open-GOP
    /// MPEG-2 I-frame with leading B's): presentation frames 2 and 3 sit just before the
    /// keyframe at 4 but decode after it — its leading pictures, count 2. The keyframe at
    /// 0 stays count 0.
    @Test func leadingCountsCountFramesPresentedBeforeButDecodedAfter() {
        let counts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: [true, false, false, false, true,  false],
            dts:           [0.00, 0.04, 0.12,  0.16,  0.08,  0.20]
        )
        #expect(counts == [0, nil, nil, nil, 2, nil])
    }

    /// A keyframe whose late-decoding predecessors are *not* the contiguous run just
    /// before it gets no count at all: the cut-before-the-keyframe arithmetic
    /// (`K − n_leading`) would not match what the muxer keeps, so it is no boundary.
    /// Here frame 1 decodes after the keyframe at 3, but frame 2 (between them) does not.
    @Test func aKeyframeWithNonContiguousReorderingIsNoBoundary() {
        let counts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: [true, false, false, true],
            dts:           [0.00, 0.10,  0.04,  0.06]
        )
        #expect(counts == [0, nil, nil, nil])
    }
}
