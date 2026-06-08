import Testing
import Foundation
@testable import VidConform

/// Exercises the pure conform argument builder (ADR-0011): given a source clip's probed
/// properties and the target clip's, it emits the ffmpeg filter chain + encoder args that
/// transform source → target. The three command shapes pinned here were each validated to
/// hit every `MatchEvaluator` dimension on the real H.264/HEVC/MPEG-2 footage in the shell.
struct ConformEngineTests {
    // The three real-clip specs as MediaProbe reports them.
    private let h264 = VideoProperties(
        codec: "h264", profile: "High", level: "40", width: 704, height: 528,
        frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: "progressive",
        sampleAspectRatio: "1:1", colorPrimaries: nil, colorTransfer: nil, colorRange: nil)
    private let mpeg2 = VideoProperties(
        codec: "mpeg2video", profile: "Main", level: "8", width: 720, height: 576,
        frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: "tt",
        sampleAspectRatio: "64:45", colorPrimaries: nil, colorTransfer: nil, colorRange: "tv")
    private let hevc = VideoProperties(
        codec: "hevc", profile: "Main 10", level: "123", width: 1920, height: 1080,
        frameRate: "50/1", pixelFormat: "yuv420p10le", fieldOrder: nil,
        sampleAspectRatio: "1:1", colorPrimaries: nil, colorTransfer: nil, colorRange: "tv")

    /// HEVC → MPEG-2: equal display aspect (both 16:9) so a plain scale-fill with no pad;
    /// progressive → interlaced needs the field-rate fps + `interlace`, and the encoder gets
    /// the top-field-first interlace flags. Validated against the MPEG-2 target spec.
    @Test func conformsHevcToInterlacedMpeg2() {
        #expect(ConformEngine.conformVideoArgs(source: hevc, target: mpeg2) == [
            "-vf", "scale=720:576,setsar=64/45,format=yuv420p,fps=50,interlace=scan=tff",
            "-c:v", "mpeg2video", "-profile:v", "main", "-flags", "+ildct+ilme", "-top", "1",
            "-color_range", "tv",
        ])
    }

    /// MPEG-2 → H.264: interlaced → progressive deinterlaces with bwdif, and a 16:9 source
    /// into a 4:3 frame letterboxes (bars top/bottom: scale 704×396, pad to 704×528 at y=66).
    /// The anamorphic source (SAR 64:45) is fitted in display space, not storage pixels.
    /// H.264 level 40 → "-level 4.0"; the target has no color range so none is set.
    @Test func conformsInterlacedMpeg2ToH264WithLetterbox() {
        #expect(ConformEngine.conformVideoArgs(source: mpeg2, target: h264) == [
            "-vf", "bwdif=mode=0,scale=704:396,pad=704:528:0:66,setsar=1/1,format=yuv420p,fps=25",
            "-c:v", "libx264", "-profile:v", "high", "-level", "4.0",
        ])
    }

    /// H.264 → HEVC: a 4:3 source into a 16:9 frame pillarboxes (bars left/right: scale
    /// 1440×1080, pad to 1920×1080 at x=240), 8-bit → 10-bit via `format`, 25 → 50 fps by
    /// duplication. HEVC level 123 = general_level_idc 4.1 → `level-idc=4.1`.
    @Test func conformsH264ToHevcWithPillarboxAnd10Bit() {
        #expect(ConformEngine.conformVideoArgs(source: h264, target: hevc) == [
            "-vf", "scale=1440:1080,pad=1920:1080:240:0,setsar=1/1,format=yuv420p10le,fps=50",
            "-c:v", "libx265", "-profile:v", "main10", "-x265-params", "log-level=error:level-idc=4.1",
            "-color_range", "tv",
        ])
    }

    /// An unrecognised target profile is omitted rather than guessed — a wrong `-profile:v`
    /// token aborts the encode, and the encoder infers a profile from the pixel format.
    @Test func unmappedProfileIsDropped() {
        var weird = h264; weird.profile = "Some Exotic Profile"
        let args = ConformEngine.conformVideoArgs(source: hevc, target: weird)
        #expect(!args.contains("-profile:v"))
        #expect(args.contains("libx264") && args.contains("-level"))
    }

    // MARK: audio conform (ADR-0011)

    /// A conforming clip's audio is resampled and remixed to the target rate and channels
    /// before it enters the sample-level concat, so the concat inputs stay aligned.
    @Test func audioFilterResamplesAndRemixesToTarget() {
        #expect(ConformEngine.audioFilter(sampleRate: 48000, channels: 2)
            == "aresample=48000,aformat=channel_layouts=stereo")
        #expect(ConformEngine.audioFilter(sampleRate: 44100, channels: 1)
            == "aresample=44100,aformat=channel_layouts=mono")
    }
}
