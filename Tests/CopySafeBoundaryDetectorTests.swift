import Testing
@testable import VidConform

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
}

/// The M1 clean-cut notion and the M2 copy-safe notion are deliberately distinct
/// (ADR-0009): on the *same* open-GOP MPEG-2 data, M1 marks every I-frame a clean cut
/// point (its copy→copy concat keeps the leading B's referenced GOP), but M2 must
/// exclude the open keyframe (its re-encode→copy seam orphans those leading pictures).
struct CleanCutVsCopySafeDistinctionTests {
    private let keyframeFlags = [true, false, true,  false, false]
    private let dts           = [0.00, 0.04, 0.02,  0.06,  0.08]

    @Test func mpeg2CleanCutTreatsEveryIFrameAsClean() {
        let clean = CleanCutDetector.cleanCutFlags(
            keyframeFlags: keyframeFlags, dts: dts, codec: "mpeg2video")
        #expect(clean == [true, false, true, false, false])
    }

    @Test func copySafeExcludesTheOpenKeyframeOnTheSameData() {
        let copySafe = CopySafeBoundaryDetector.copySafeFlags(
            keyframeFlags: keyframeFlags, dts: dts)
        #expect(copySafe == [true, false, false, false, false])
        #expect(copySafe != CleanCutDetector.cleanCutFlags(
            keyframeFlags: keyframeFlags, dts: dts, codec: "mpeg2video"))
    }
}
