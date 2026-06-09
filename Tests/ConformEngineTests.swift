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
    /// H.264 level 40 → "-level 4.0". The target is fully untagged (an SD SATRip), so the chain
    /// ends with `setparams=...=unknown` to strip any source color tags and match it.
    @Test func conformsInterlacedMpeg2ToH264WithLetterbox() {
        #expect(ConformEngine.conformVideoArgs(source: mpeg2, target: h264) == [
            "-vf", "bwdif=mode=0,scale=704:396,pad=704:528:0:66,setsar=1/1,format=yuv420p,fps=25,"
                + "setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown:range=unknown",
            "-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-x264-params", "b-pyramid=0",
        ])
    }

    /// A fully color-tagged source (bt709 HD) conforming to an untagged target must have its color
    /// metadata stripped, or the propagated VUI fails self-verify against the untagged target — the
    /// MKV→SD-H.264 case that surfaced in real use. A target that *does* carry color (the MPEG-2
    /// target's `tv` range) is left alone: stripping is only for the all-untagged target.
    @Test func untaggedTargetStripsColorButTaggedTargetDoesNot() {
        var tagged = h264
        tagged.colorPrimaries = "bt709"; tagged.colorTransfer = "bt709"; tagged.colorRange = "tv"
        #expect(ConformEngine.conformVideoArgs(source: tagged, target: h264)
            .contains { $0.contains("setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown:range=unknown") })
        // mpeg2 target carries a color range, so no strip is appended.
        #expect(!ConformEngine.conformVideoArgs(source: hevc, target: mpeg2)
            .contains { $0.contains("setparams") })
    }

    /// H.264 → HEVC: a 4:3 source into a 16:9 frame pillarboxes (bars left/right: scale
    /// 1440×1080, pad to 1920×1080 at x=240), 8-bit → 10-bit via `format`, 25 → 50 fps by
    /// duplication. HEVC level 123 = general_level_idc 4.1 → `level-idc=4.1`.
    @Test func conformsH264ToHevcWithPillarboxAnd10Bit() {
        #expect(ConformEngine.conformVideoArgs(source: h264, target: hevc) == [
            "-vf", "scale=1440:1080,pad=1920:1080:240:0,setsar=1/1,format=yuv420p10le,fps=50",
            "-c:v", "libx265", "-profile:v", "main10",
            "-x265-params", "log-level=error:level-idc=4.1:b-pyramid=0",
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

    // MARK: full conform command (kept range)

    private let src = URL(fileURLWithPath: "/clips/in.mkv")
    private let out = URL(fileURLWithPath: "/tmp/conf.ts")

    /// Conform re-encodes only the kept range as a time window (ADR-0011): a fast seek to the
    /// in-point time and a read duration, then the transform args, dropping audio (rebuilt
    /// separately). An open end reads to the file end (no `-t`).
    @Test func conformArgumentsSeekTheKeptRangeAndDropAudio() {
        #expect(ConformEngine.conformArguments(
            source: src, start: 5.0, end: 9.0, sourceVideo: hevc, targetVideo: mpeg2, output: out)
            == ["-v", "error", "-ss", "5", "-t", "4", "-i", src.path]
                + ConformEngine.conformVideoArgs(source: hevc, target: mpeg2)
                + ["-an", out.path])
    }

    @Test func conformArgumentsOmitSeekAndDurationAtClipBounds() {
        let args = ConformEngine.conformArguments(
            source: src, start: nil, end: nil, sourceVideo: hevc, targetVideo: mpeg2, output: out)
        #expect(!args.contains("-ss") && !args.contains("-t"))
        #expect(args.prefix(4) == ["-v", "error", "-i", src.path])
    }

    // MARK: relaxed frame-count (ADR-0011)

    /// M2's exact frame-count assertion is relaxed for conformed pieces to `duration × target_fps`
    /// (±1, checked in verifyConformed), since fps conversion legitimately changes the count: a 10 s
    /// window is 250 frames at 25 fps and 500 at 50 fps. A fractional rate rounds (10 × 29.97 ≈ 300).
    @Test func expectedFrameCountIsWindowDurationTimesTargetRate() {
        #expect(ConformEngine.expectedFrameCount(windowDuration: 10, targetFrameRate: "25/1") == 250)
        #expect(ConformEngine.expectedFrameCount(windowDuration: 10, targetFrameRate: "50/1") == 500)
        #expect(ConformEngine.expectedFrameCount(windowDuration: 10, targetFrameRate: "30000/1001") == 300)
    }

    /// A non-positive window or an unparseable rate yields no expectation, so verifyConformed skips
    /// the count check rather than failing a clip blind.
    @Test func expectedFrameCountIsNilWhenUncomputable() {
        #expect(ConformEngine.expectedFrameCount(windowDuration: 0, targetFrameRate: "25/1") == nil)
        #expect(ConformEngine.expectedFrameCount(windowDuration: 10, targetFrameRate: "") == nil)
        #expect(ConformEngine.expectedFrameCount(windowDuration: 10, targetFrameRate: "25/0") == nil)
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
