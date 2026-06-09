import Testing
import Foundation
@testable import VidConform

/// Exercises the pure ffmpeg argument builders for the Milestone 2 boundary re-encode
/// (ADR-0009). The recipes themselves were validated frame-exact against real
/// H.264/HEVC/MPEG-2 footage in the shell; these tests pin the exact command shape.
struct BoundaryReencodeEngineTests {
    private let src = URL(fileURLWithPath: "/clips/in.ts")
    private let out = URL(fileURLWithPath: "/tmp/seg.ts")

    // MARK: encoder args (matched to the source — ADR-0009)

    @Test func h264ReencodesWithLibx264AtTheSourcePixelFormat() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "h264", pixelFormat: "yuv420p", fieldOrder: "progressive")
            == ["-c:v", "libx264", "-pix_fmt", "yuv420p"])
    }

    @Test func hevcReencodesWithLibx265Keeping10Bit() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "hevc", pixelFormat: "yuv420p10le", fieldOrder: "unknown")
            == ["-c:v", "libx265", "-pix_fmt", "yuv420p10le"])
    }

    @Test func mpeg2ReencodesInterlacedTopFieldFirst() {
        // ffmpeg carries SAR through automatically, so no -aspect is needed; the
        // interlace flags preserve field_order=tt (verified in the shell).
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "mpeg2video", pixelFormat: "yuv420p", fieldOrder: "tt")
            == ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p", "-flags", "+ildct+ilme", "-top", "1"])
    }

    @Test func progressiveMpeg2HasNoInterlaceFlags() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "mpeg2video", pixelFormat: "yuv420p", fieldOrder: "progressive")
            == ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p"])
    }

    // MARK: source-profile matching (ADR-0009)

    /// A recognised source profile is pinned with `-profile:v` so an unusual source still
    /// matches — e.g. a Baseline H.264 clip that the encoder would otherwise lift to High.
    @Test func aKnownSourceProfileIsMatchedExplicitly() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "h264", profile: "Baseline", pixelFormat: "yuv420p", fieldOrder: "progressive")
            == ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "baseline"])
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "hevc", profile: "Main 10", pixelFormat: "yuv420p10le", fieldOrder: "unknown")
            == ["-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-profile:v", "main10"])
        // The profile arg precedes the interlace flags for MPEG-2.
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "mpeg2video", profile: "Main", pixelFormat: "yuv420p", fieldOrder: "tt")
            == ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p", "-profile:v", "main",
                "-flags", "+ildct+ilme", "-top", "1"])
    }

    /// An unrecognised profile is omitted rather than guessed (a wrong token aborts the
    /// encode); the encoder then infers a profile from the pixel format, which matches the
    /// source for every common case.
    @Test func anUnknownProfileIsOmittedNotGuessed() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "h264", profile: "Some Exotic Profile", pixelFormat: "yuv420p", fieldOrder: "progressive")
            == ["-c:v", "libx264", "-pix_fmt", "yuv420p"])
        #expect(BoundaryReencodeEngine.encoderProfile(nil, codec: "h264") == nil)
        #expect(BoundaryReencodeEngine.encoderProfile("Main 10", codec: "mpeg2video") == nil)
    }

    // MARK: head/tail re-encode

    /// Re-encodes a partial-GOP range by input-seeking to the keyframe at/before the
    /// range start (so only ~one GOP decodes, not the whole file) and selecting frames
    /// RELATIVE to that keyframe — which the decoder emits as n=0 after the seek. The
    /// seek is start_time-relative (the stream starts at 0.24 here), so the first
    /// presentation PTS is subtracted.
    @Test func reencodeSegmentSeeksToKeyframeAndSelectsRelativeFrames() {
        // 8 frames starting at 0.24; keyframes at 0 and 4.
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        // Tail range [6,8): frames 6,7. Keyframe at/before 6 is 4; seek = 0.40-0.24 = 0.16;
        // relative select between 6-4=2 and 7-4=3.
        let args = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 6..<8, index: index,
            encoder: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], output: out)
        #expect(args == [
            "-v", "error", "-ss", "0.16", "-i", src.path,
            "-vf", "select='between(n\\,2\\,3)',setpts=PTS-STARTPTS",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", out.path,
        ])
    }

    // MARK: middle stream-copy

    /// A copy segment is executed by mapping it onto M1's validated segment-muxer cut: an
    /// interior span (neither end a clip boundary) cuts at both copy-safe boundaries and
    /// keeps the middle piece. The DTS-midpoint cut times are start_time-corrected.
    @Test func copySegmentBecomesAnInteriorTwoCutPlan() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, true])
        // copy 4..<7 with 8 frames total: both ends interior -> cut at 4 and 7.
        let plan = BoundaryReencodeEngine.copySegmentPlan(copyRange: 4..<7, index: index)
        #expect(abs((plan.inSegmentTime ?? -1) - 0.14) < 1e-9)   // (0.36+0.40)/2 - 0.24
        #expect(abs((plan.outSegmentTime ?? -1) - 0.26) < 1e-9)  // (0.48+0.52)/2 - 0.24
        #expect(ExportEngine.wantedSegmentIndex(plan: plan) == 1)
        #expect(ExportEngine.needsCut(plan))
    }

    /// A copy that runs to the file end needs no out-cut, and one from the file start
    /// needs no in-cut — so a whole-clip copy is a plain remux (M1 behaviour reused).
    @Test func copySegmentOmitsCutsAtClipBoundaries() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, true])
        let whole = BoundaryReencodeEngine.copySegmentPlan(copyRange: 0..<8, index: index)
        #expect(whole.inSegmentTime == nil && whole.outSegmentTime == nil)
        #expect(!ExportEngine.needsCut(whole))

        let toEnd = BoundaryReencodeEngine.copySegmentPlan(copyRange: 4..<8, index: index)
        #expect(toEnd.inSegmentTime != nil && toEnd.outSegmentTime == nil)
        #expect(ExportEngine.wantedSegmentIndex(plan: toEnd) == 1)
    }

    // MARK: output verification (ADR-0008)

    /// The expected frame count a produced piece is verified against is the planned
    /// segments' combined length — they tile the kept range contiguously, so a head
    /// re-encode + copy + tail re-encode that kept frames [3,12) totals 9.
    @Test func expectedFrameCountIsTheCombinedSegmentLength() {
        let plan = [
            PlannedSegment(kind: .reEncode, range: 3..<5),
            PlannedSegment(kind: .copy, range: 5..<10),
            PlannedSegment(kind: .reEncode, range: 10..<12),
        ]
        #expect(BoundaryReencodeEngine.expectedFrameCount(plan) == 9)
        // A whole-clip single-copy plan: its own length.
        #expect(BoundaryReencodeEngine.expectedFrameCount(
            [PlannedSegment(kind: .copy, range: 0..<100)]) == 100)
    }

    /// The concat `duration` directive for each segment is the exact presentation-time span
    /// to the next segment's first frame (`pts[hi] - pts[lo]`), closing the start_time seam
    /// gap without a frame-rate estimate. The final segment runs to the clip end, where
    /// `pts[hi]` is out of bounds, so it carries no directive (`nil`) — its span never offsets
    /// a following piece (the start_time off-by-one, ADR-0008).
    @Test func segmentSpansAreExactPresentationOffsetsLastIsNil() {
        // A source at start_time 0.24, 25fps. Copy [0,4) then re-encode [4,8) to the end.
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let plan = [
            PlannedSegment(kind: .copy, range: 0..<4),
            PlannedSegment(kind: .reEncode, range: 4..<8),
        ]
        let spans = BoundaryReencodeEngine.segmentSpans(plan, index: index)
        #expect(spans.count == 2)
        #expect(abs((spans[0] ?? -1) - 0.16) < 1e-9)   // pts[4] - pts[0] = 0.40 - 0.24, = 4 frames
        #expect(spans[1] == nil)                        // runs to the clip end → no directive
    }
}
