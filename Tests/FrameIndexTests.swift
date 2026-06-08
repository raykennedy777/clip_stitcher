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

/// With B-frames, packets are reordered: a keyframe's decode time (DTS) is earlier
/// than its presentation time (PTS), and the segment muxer cuts on DTS. The cut time
/// must therefore be a DTS midpoint, not a PTS one — a PTS-based time can fall *after*
/// the keyframe's DTS and make ffmpeg skip past it to the next keyframe (verified in
/// the shell against B-frame MP4; ADR-0008).
struct SegmentTimeWithBFramesTests {
    // A 6-frame IPBB-style stream. Presentation order (sorted by PTS); the keyframe
    // at presentation frame 3 presents at 0.12 but decodes at 0.06 (B-frames 4,5
    // present before, in presentation order, frames 1,2 — its leading siblings).
    //   pres frame: 0    1     2     3(K)  4     5
    //   pts:        0.00 0.04  0.08  0.12  0.16  0.20
    //   dts:        0.00 0.02  0.04  0.06  0.08  0.10
    private let index = FrameIndex(
        pts: [0.00, 0.04, 0.08, 0.12, 0.16, 0.20],
        dts: [0.00, 0.02, 0.04, 0.06, 0.08, 0.10],
        keyframeFlags: [true, false, false, true, false, false]
    )

    @Test func segmentTimeUsesDecodeTimeNotPresentationTime() {
        // Keyframe at presentation frame 3: dts 0.06, decode-predecessor dts 0.04
        // -> midpoint 0.05. (A PTS midpoint would be (0.08+0.12)/2 = 0.10, which is
        // past the keyframe's dts and would skip it.)
        #expect(abs(index.segmentTime(forCutAt: 3) - 0.05) < 1e-9)
    }
}

/// A real source rarely starts at timestamp zero: the container reports a `start_time`
/// (the first presentation frame's PTS), and ffmpeg's segment muxer measures
/// `-segment_times` *relative to it* — it subtracts start_time before comparing each
/// keyframe's decode time. So the cut time must have that start offset removed, or the
/// muxer lands one keyframe late on any non-zero-start_time source (verified: the MPEG-2
/// test clip starts at 0.24s and otherwise cuts a full GOP late). Zero-start sources are
/// unaffected, which is why the cases above — all starting at 0.0 — need no adjustment.
struct SegmentTimeStartOffsetTests {
    // The IPBB shape above, shifted so the stream starts at start_time 0.24:
    //   pres frame: 0     1     2     3(K)  4     5
    //   pts:        0.24  0.28  0.32  0.36  0.40  0.44
    //   dts:        0.20  0.22  0.24  0.26  0.28  0.30
    private let index = FrameIndex(
        pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44],
        dts: [0.20, 0.22, 0.24, 0.26, 0.28, 0.30],
        keyframeFlags: [true, false, false, true, false, false]
    )

    @Test func segmentTimeSubtractsTheStreamStartTime() {
        // Keyframe at presentation frame 3: dts 0.26, decode-predecessor dts 0.24
        // -> midpoint 0.25; minus the 0.24 start_time -> 0.01.
        #expect(abs(index.segmentTime(forCutAt: 3) - 0.01) < 1e-9)
    }
}
