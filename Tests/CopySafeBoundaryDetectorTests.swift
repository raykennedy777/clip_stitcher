import Testing
@testable import ClipStitcher

struct CopySafeBoundaryDetectorTests {
    @Test func everyKeyframeIsCopySafeInAClosedGop() {
        let flags = CopySafeBoundaryDetector.copySafeFlags(
            keyframeFlags: [true, false, false, true, false],
            dts:           [0.00, 0.04, 0.08, 0.12, 0.16]
        )
        #expect(flags == [true, false, false, true, false])
    }

    @Test func anOpenKeyframeWithLeadingPicturesIsNotCopySafe() {
        let flags = CopySafeBoundaryDetector.copySafeFlags(
            keyframeFlags: [true, false, true,  false, false],
            dts:           [0.00, 0.04, 0.02,  0.06,  0.08]
        )
        #expect(flags == [true, false, false, false, false])
    }

    @Test func leadingCountsAreZeroAtClosedGopKeyframes() {
        let counts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: [true, false, false, true, false],
            dts:           [0.00, 0.04, 0.08, 0.12, 0.16]
        )
        #expect(counts == [0, nil, nil, 0, nil])
    }

    @Test func leadingCountsCountFramesPresentedBeforeButDecodedAfter() {
        let counts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: [true, false, false, false, true,  false],
            dts:           [0.00, 0.04, 0.12,  0.16,  0.08,  0.20]
        )
        #expect(counts == [0, nil, nil, nil, 2, nil])
    }

    @Test func aKeyframeWithNonContiguousReorderingIsNoBoundary() {
        let counts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: [true, false, false, true],
            dts:           [0.00, 0.10,  0.04,  0.06]
        )
        #expect(counts == [0, nil, nil, nil])
    }
}
