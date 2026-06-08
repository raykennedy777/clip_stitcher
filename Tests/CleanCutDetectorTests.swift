import Testing
@testable import VidConform

/// Exercises clean-cut-point detection (ADR-0008): which keyframes a pure stream-copy
/// can cut at frame-exactly. A keyframe is clean when it has no *leading pictures* —
/// no frame that presents before it (smaller presentation index) yet decodes after it
/// (larger DTS). MPEG-2 is the exception: every I-frame cuts clean regardless.
struct CleanCutDetectorTests {
    @Test func everyKeyframeIsCleanWithoutBFrames() {
        // dts == pts (no reordering): no keyframe has leading pictures.
        let dts = [0.0, 1, 2, 3, 4, 5, 6, 7]
        let key = [true, false, false, false, false, true, false, false]
        let flags = CleanCutDetector.cleanCutFlags(keyframeFlags: key, dts: dts, codec: "h264")
        #expect(flags == key)
    }

    @Test func aKeyframeWithLeadingPicturesIsNotClean() {
        // Presentation frame 4 decodes (dts 5) *after* the keyframe at frame 5 (dts 4),
        // while presenting before it — a leading picture of keyframe 5. So keyframe 5
        // is open; keyframe 0 (no earlier frames) is clean.
        let dts = [0.0, 1, 2, 3, 5, 4, 6, 7]
        let key = [true, false, false, false, false, true, false, false]
        let flags = CleanCutDetector.cleanCutFlags(keyframeFlags: key, dts: dts, codec: "hevc")
        #expect(flags == [true, false, false, false, false, false, false, false])
    }

    @Test func mpeg2TreatsEveryKeyframeAsCleanDespiteLeadingPictures() {
        // Same leading-picture layout as above, but MPEG-2 cuts clean at every I-frame.
        let dts = [0.0, 1, 2, 3, 5, 4, 6, 7]
        let key = [true, false, false, false, false, true, false, false]
        let flags = CleanCutDetector.cleanCutFlags(keyframeFlags: key, dts: dts, codec: "mpeg2video")
        #expect(flags == key)
    }

    @Test func unknownCodecFallsBackToTheLeadingPictureTest() {
        let dts = [0.0, 1, 2, 3, 5, 4, 6, 7]
        let key = [true, false, false, false, false, true, false, false]
        let flags = CleanCutDetector.cleanCutFlags(keyframeFlags: key, dts: dts, codec: nil)
        #expect(flags == [true, false, false, false, false, false, false, false])
    }
}
