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

    /// Stream-copies the keyframe-bounded middle by cutting the segment muxer at both
    /// copy-safe boundaries (start_time-corrected DTS midpoints) and keeping the piece
    /// between them — segment index 1.
    @Test func copyMiddleCutsAtBothBoundaries() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, true])
        // copyRange 4..<7: cut at frame 4 -> (0.36+0.40)/2 - 0.24 = 0.14;
        //                  cut at frame 7 -> (0.48+0.52)/2 - 0.24 = 0.26.
        let args = BoundaryReencodeEngine.copyMiddleArguments(
            source: src, copyRange: 4..<7, index: index, segmentPattern: "/tmp/mid_%03d.ts")
        #expect(args == [
            "-v", "error", "-i", src.path, "-map", "0:v:0", "-c", "copy",
            "-f", "segment", "-segment_times", "0.14,0.26",
            "-reset_timestamps", "1", "/tmp/mid_%03d.ts",
        ])
        #expect(BoundaryReencodeEngine.middleSegmentIndex == 1)
    }
}
