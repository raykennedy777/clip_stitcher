import Testing
import Foundation
@testable import ClipStitcher

struct ConformEngineTests {
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

    @Test func conformsHevcToInterlacedMpeg2() {
        #expect(ConformEngine.conformVideoArgs(source: hevc, target: mpeg2) == [
            "-vf", "scale=720:576,setsar=64/45,format=yuv420p,fps=50,interlace=scan=tff",
            "-c:v", "mpeg2video", "-profile:v", "main", "-flags", "+ildct+ilme",
            "-color_range", "tv",
        ])
    }

    @Test func anInterlacedTargetGetsItsScanDirectionFromTheChainTail() {
        let bff = VideoProperties(
            codec: "mpeg2video", profile: "Main", level: nil, width: 720, height: 576,
            frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: "bb",
            sampleAspectRatio: "64:45", colorPrimaries: nil, colorTransfer: nil, colorRange: "tv")
        let args = ConformEngine.conformVideoArgs(source: mpeg2, target: bff)
        #expect(!args.contains("-top"))
        #expect(args[args.firstIndex(of: "-vf")! + 1].hasSuffix(",setparams=field_mode=bff"))
        #expect(args[args.firstIndex(of: "-flags")! + 1] == "+ildct+ilme")
        #expect(!args[args.firstIndex(of: "-vf")! + 1].contains("bwdif"))
        #expect(!args[args.firstIndex(of: "-vf")! + 1].contains("interlace=scan"))

        let tff = ConformEngine.conformVideoArgs(source: mpeg2, target: mpeg2)
        #expect(tff[tff.firstIndex(of: "-vf")! + 1].hasSuffix(",setparams=field_mode=tff"))
    }

    @Test func conformsProgressiveH264ToInterlacedH264() {
        var tt = h264; tt.width = 720; tt.height = 576; tt.frameRate = "50/1"
        tt.fieldOrder = "tt"; tt.sampleAspectRatio = "16:15"
        #expect(ConformEngine.conformVideoArgs(source: h264, target: tt) == [
            "-vf", "scale=720:576,setsar=16/15,format=yuv420p,fps=50,setparams=field_mode=tff,"
                + "setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown:range=unknown",
            "-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-flags", "+ildct+ilme",
            "-x264-params", "b-pyramid=0",
        ])
        var tb = tt; tb.fieldOrder = "tb"
        #expect(ConformEngine.conformVideoArgs(source: h264, target: tb)
            == ConformEngine.conformVideoArgs(source: h264, target: tt))
    }

    @Test func weavesOnlyWhenTheSourceSuppliesTheFieldRate() {
        var target = h264; target.fieldOrder = "tt"; target.frameRate = "25/1"
        func tail(_ sourceRate: String) -> String {
            var src = h264; src.frameRate = sourceRate
            let args = ConformEngine.conformVideoArgs(source: src, target: target)
            return args[args.firstIndex(of: "-vf")! + 1]
        }
        #expect(tail("50/1").contains("fps=50,interlace=scan=tff"))
        #expect(tail("60000/1001").contains("fps=50,interlace=scan=tff"))
        #expect(tail("25/1").contains("fps=25,setparams=field_mode=tff"))
        #expect(!tail("25/1").contains("interlace="))
        #expect(tail("30000/1001").contains("fps=25,setparams=field_mode=tff"))
        var bff = target; bff.fieldOrder = "bb"
        var src = h264; src.frameRate = "25/1"
        #expect(ConformEngine.conformVideoArgs(source: src, target: bff)
            .contains { $0.contains("fps=25,setparams=field_mode=bff") })
        var isrc = h264; isrc.fieldOrder = "tt"
        #expect(!ConformEngine.conformVideoArgs(source: isrc, target: target).contains { $0.contains("interlace=") })
    }

    @Test func interlacedH264SourceGetsTheScanFilterForAnInterlacedH264Target() {
        var tt = h264; tt.fieldOrder = "tt"
        var bb = h264; bb.fieldOrder = "bb"
        let args = ConformEngine.conformVideoArgs(source: tt, target: bb)
        #expect(args[args.firstIndex(of: "-vf")! + 1].hasSuffix(",setparams=field_mode=bff"))
        #expect(!args[args.firstIndex(of: "-vf")! + 1].contains("interlace=scan"))
        #expect(args[args.firstIndex(of: "-flags")! + 1] == "+ildct+ilme")
        var ihevc = hevc; ihevc.fieldOrder = "tt"
        let h = ConformEngine.conformVideoArgs(source: ihevc, target: ihevc)
        #expect(!h.contains("-flags"))
        #expect(!h.contains { $0.contains("field_mode") })
    }

    @Test func conformsInterlacedMpeg2ToH264WithLetterbox() {
        #expect(ConformEngine.conformVideoArgs(source: mpeg2, target: h264) == [
            "-vf", "bwdif=mode=0,scale=704:396,pad=704:528:0:66,setsar=1/1,format=yuv420p,fps=25,"
                + "setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown:range=unknown",
            "-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-x264-params", "b-pyramid=0",
        ])
    }

    @Test func untaggedTargetStripsColorButTaggedTargetDoesNot() {
        var tagged = h264
        tagged.colorPrimaries = "bt709"; tagged.colorTransfer = "bt709"; tagged.colorRange = "tv"
        #expect(ConformEngine.conformVideoArgs(source: tagged, target: h264)
            .contains { $0.contains("setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown:range=unknown") })
        #expect(!ConformEngine.conformVideoArgs(source: hevc, target: mpeg2)
            .contains { $0.contains("setparams") })
    }

    @Test func conformsH264ToHevcWithPillarboxAnd10Bit() {
        #expect(ConformEngine.conformVideoArgs(source: h264, target: hevc) == [
            "-vf", "scale=1440:1080,pad=1920:1080:240:0,setsar=1/1,format=yuv420p10le,fps=50",
            "-c:v", "libx265", "-profile:v", "main10",
            "-x265-params", "log-level=error:level-idc=4.1:b-pyramid=0",
            "-color_range", "tv",
        ])
    }

    @Test func aDeepJoinKeepsTheConformsBPyramid() {
        let deep = ConformEngine.conformVideoArgs(source: h264, target: hevc, reorderDepth: 2)
        #expect(deep == [
            "-vf", "scale=1440:1080,pad=1920:1080:240:0,setsar=1/1,format=yuv420p10le,fps=50",
            "-c:v", "libx265", "-profile:v", "main10",
            "-x265-params", "log-level=error:level-idc=4.1",
            "-color_range", "tv",
        ])
        #expect(!ConformEngine.conformVideoArgs(source: mpeg2, target: h264, reorderDepth: 2)
            .contains("-x264-params"))
        #expect(ConformEngine.conformVideoArgs(source: h264, target: hevc, reorderDepth: 1)
            == ConformEngine.conformVideoArgs(source: h264, target: hevc))
        #expect(ConformEngine.conformVideoArgs(source: hevc, target: mpeg2, reorderDepth: 2)
            == ConformEngine.conformVideoArgs(source: hevc, target: mpeg2))
    }

    @Test func conformCrfPinsRateControlOnX264AndX265ButNotMpeg2() {
        #expect(ConformEngine.conformVideoArgs(source: h264, target: hevc, crf: 21) == [
            "-vf", "scale=1440:1080,pad=1920:1080:240:0,setsar=1/1,format=yuv420p10le,fps=50",
            "-c:v", "libx265", "-profile:v", "main10", "-crf", "21",
            "-x265-params", "log-level=error:level-idc=4.1:b-pyramid=0",
            "-color_range", "tv",
        ])
        #expect(ConformEngine.conformVideoArgs(source: mpeg2, target: h264, crf: 18) == [
            "-vf", "bwdif=mode=0,scale=704:396,pad=704:528:0:66,setsar=1/1,format=yuv420p,fps=25,"
                + "setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown:range=unknown",
            "-c:v", "libx264", "-profile:v", "high", "-crf", "18", "-level", "4.0",
            "-x264-params", "b-pyramid=0",
        ])
        #expect(ConformEngine.conformVideoArgs(source: hevc, target: mpeg2, crf: 21)
            == ConformEngine.conformVideoArgs(source: hevc, target: mpeg2))
        #expect(ConformEngine.conformVideoArgs(source: h264, target: hevc, crf: nil)
            == ConformEngine.conformVideoArgs(source: h264, target: hevc))
    }

    @Test func unmappedProfileIsDropped() {
        var weird = h264; weird.profile = "Some Exotic Profile"
        let args = ConformEngine.conformVideoArgs(source: hevc, target: weird)
        #expect(!args.contains("-profile:v"))
        #expect(args.contains("libx264") && args.contains("-level"))
    }

    private let france = VideoProperties(
        codec: "h264", profile: "High", level: "51", width: 704, height: 576,
        frameRate: "50/1", pixelFormat: "yuv420p", fieldOrder: "progressive",
        sampleAspectRatio: "12:11", colorPrimaries: "bt709", colorTransfer: "bt709",
        colorSpace: "bt470bg", colorRange: "tv")

    @Test func convertsUntaggedSDTowardTaggedTargetWithAssumed601() {
        #expect(ConformEngine.conformVideoArgs(source: mpeg2, target: france) == [
            "-vf", "bwdif=mode=0,scale=704:432,pad=704:576:0:72,setsar=12/11,format=yuv420p,"
                + "colorspace=ispace=bt470bg:iprimaries=bt470bg:itrc=smpte170m:irange=tv"
                + ":space=bt470bg:primaries=bt709:trc=bt709:range=tv,fps=50",
            "-c:v", "libx264", "-profile:v", "high", "-level", "5.1",
            "-x264-params", "b-pyramid=0", "-color_range", "tv",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt470bg",
        ])
    }

    @Test func convertsUntaggedHDTowardTaggedTargetWithAssumed709() {
        #expect(ConformEngine.conformVideoArgs(source: hevc, target: france) == [
            "-vf", "scale=704:432,pad=704:576:0:72,setsar=12/11,format=yuv420p,"
                + "colorspace=ispace=bt709:iprimaries=bt709:itrc=bt709:irange=tv"
                + ":space=bt470bg:primaries=bt709:trc=bt709:range=tv,fps=50",
            "-c:v", "libx264", "-profile:v", "high", "-level", "5.1",
            "-x264-params", "b-pyramid=0", "-color_range", "tv",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt470bg",
        ])
    }

    @Test func assumedSpecMatchingTargetTagsWithoutConverting() {
        var target601 = mpeg2
        target601.colorPrimaries = "bt470bg"; target601.colorTransfer = "smpte170m"
        target601.colorSpace = "bt470bg"
        let args = ConformEngine.conformVideoArgs(source: mpeg2, target: target601)
        #expect(args[1].contains(
            "setparams=color_primaries=bt470bg:color_trc=smpte170m:colorspace=bt470bg:range=tv"))
        #expect(!args[1].contains("colorspace=ispace"))
        #expect(args.contains("-color_primaries") && args.contains("smpte170m"))
    }

    @Test func taggedSourceMatchingTargetSkipsTheColorStage() {
        #expect(ConformEngine.colorStage(source: france, target: france) == nil)
        var smaller = france; smaller.width = 352; smaller.height = 288
        let args = ConformEngine.conformVideoArgs(source: smaller, target: france)
        #expect(!args[1].contains("colorspace") && !args[1].contains("setparams"))
        #expect(args.suffix(6) == ["-color_primaries", "bt709", "-color_trc", "bt709",
                                   "-colorspace", "bt470bg"])
    }

    @Test func assumedColorTripleFollowsTheIndustryHeuristic() {
        #expect(ConformEngine.assumedColorTriple(height: 576, frameRate: "25/1")
            == ("bt470bg", "smpte170m", "bt470bg"))
        #expect(ConformEngine.assumedColorTriple(height: 480, frameRate: "30000/1001")
            == ("smpte170m", "smpte170m", "smpte170m"))
        #expect(ConformEngine.assumedColorTriple(height: 1080, frameRate: "50/1")
            == ("bt709", "bt709", "bt709"))
    }

    @Test func assumedColorWarningNamesTheAssumptionOnlyWhenUsed() {
        let warned = ConformEngine.assumedColorWarning(clipName: "Broadcast", source: mpeg2, target: france)
        #expect(warned?.contains("BT.601 (625-line)") == true && warned?.contains("Broadcast") == true)
        #expect(ConformEngine.assumedColorWarning(clipName: "f", source: france, target: france) == nil)
        #expect(ConformEngine.assumedColorWarning(clipName: "x", source: mpeg2, target: h264) == nil)
    }

    @Test func partiallyTaggedTargetGetsNoConversion() {
        var partial = h264; partial.colorPrimaries = "bt709"
        let args = ConformEngine.conformVideoArgs(source: mpeg2, target: partial)
        #expect(!args[1].contains("colorspace") && !args.contains("-color_primaries"))
    }

    private let src = URL(fileURLWithPath: "/clips/in.mkv")
    private let out = URL(fileURLWithPath: "/tmp/conf.ts")

    @Test func conformArgumentsSeekTheKeptRangeAndDropAudio() {
        #expect(ConformEngine.conformArguments(
            source: src, start: 5.0, end: 9.0, sourceVideo: hevc, targetVideo: mpeg2, output: out)
            == ["-v", "error", "-ss", "5", "-t", "4", "-i", src.path]
                + ConformEngine.conformVideoArgs(source: hevc, target: mpeg2)
                + ["-bsf:v", ExportEngine.parameterSetRepeatFilter]
                + ["-an", out.path])
    }

    @Test func conformArgumentsOmitSeekAndDurationAtClipBounds() {
        let args = ConformEngine.conformArguments(
            source: src, start: nil, end: nil, sourceVideo: hevc, targetVideo: mpeg2, output: out)
        #expect(!args.contains("-ss") && !args.contains("-t"))
        #expect(args.prefix(4) == ["-v", "error", "-i", src.path])
    }

    @Test func conformArgumentsCarryTheExportWideTimescaleWhenSet() {
        let pinned = ConformEngine.conformArguments(
            source: src, start: nil, end: nil, sourceVideo: hevc, targetVideo: mpeg2,
            output: out, trackTimescale: 450000)
        let i = pinned.firstIndex(of: "-video_track_timescale")
        #expect(i != nil && pinned[pinned.index(after: i!)] == "450000")
        let plain = ConformEngine.conformArguments(
            source: src, start: nil, end: nil, sourceVideo: hevc, targetVideo: mpeg2, output: out)
        #expect(!plain.contains("-video_track_timescale"))
    }

    @Test func expectedFrameCountIsWindowDurationTimesTargetRate() {
        #expect(ConformEngine.expectedFrameCount(windowDuration: 10, targetFrameRate: "25/1") == 250)
        #expect(ConformEngine.expectedFrameCount(windowDuration: 10, targetFrameRate: "50/1") == 500)
        #expect(ConformEngine.expectedFrameCount(windowDuration: 10, targetFrameRate: "30000/1001") == 300)
    }

    @Test func expectedFrameCountIsNilWhenUncomputable() {
        #expect(ConformEngine.expectedFrameCount(windowDuration: 0, targetFrameRate: "25/1") == nil)
        #expect(ConformEngine.expectedFrameCount(windowDuration: 10, targetFrameRate: "") == nil)
        #expect(ConformEngine.expectedFrameCount(windowDuration: 10, targetFrameRate: "25/0") == nil)
    }

    @Test func audioFilterResamplesAndRemixesToTarget() {
        #expect(ConformEngine.audioFilter(sampleRate: 48000, channels: 2)
            == "aresample=48000,aformat=channel_layouts=stereo")
        #expect(ConformEngine.audioFilter(sampleRate: 44100, channels: 1)
            == "aresample=44100,aformat=channel_layouts=mono")
    }

    @Test func audioFilterGapFillMatchesTheDeRiskedString() {
        #expect(ConformEngine.audioFilter(sampleRate: 48000, channels: 2, fillGaps: true)
            == "aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo")
    }

    @Test func stereoSourceMixRecipesMatchTheDeRiskedStrings() {
        #expect(ConformEngine.mixFilter(.leftOnly, sourceChannels: 2)
            == "pan=stereo|c0=c0|c1=c0")
        #expect(ConformEngine.mixFilter(.rightOnly, sourceChannels: 2)
            == "pan=stereo|c0=c1|c1=c1")
        #expect(ConformEngine.mixFilter(.mono, sourceChannels: 2)
            == "pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1")
    }

    @Test func surroundSourceMixRecipesFoldDownFirst() {
        #expect(ConformEngine.mixFilter(.stereo, sourceChannels: 6)
            == "aformat=channel_layouts=stereo")
        #expect(ConformEngine.mixFilter(.leftOnly, sourceChannels: 6)
            == "aformat=channel_layouts=stereo,pan=stereo|c0=c0|c1=c0")
        #expect(ConformEngine.mixFilter(.mono, sourceChannels: 6)
            == "aformat=channel_layouts=stereo,pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1")
    }

    @Test func noOpMixesBuildNoFilter() {
        #expect(ConformEngine.mixFilter(.original, sourceChannels: 2) == nil)
        #expect(ConformEngine.mixFilter(.stereo, sourceChannels: 2) == nil)
        #expect(ConformEngine.mixFilter(.leftOnly, sourceChannels: 1) == nil)
        #expect(ConformEngine.mixFilter(.mono, sourceChannels: nil) == nil)
    }

    @Test func damageZonesBecomeASelectBeforeTheFpsStage() {
        let args = ConformEngine.conformVideoArgs(
            source: h264, target: hevc,
            damage: [DamageZone(start: 24.0, end: 25.5, affectsVideo: true)],
            windowStart: 10.0, windowEnd: 50.0)
        #expect(args[1] == "scale=1440:1080,pad=1920:1080:240:0,setsar=1/1,format=yuv420p10le,"
            + "select='not(between(t\\,13.99\\,15.51))',fps=50")
    }

    @Test func cleanAndOutOfWindowZonesLeaveTheChainUnchanged() {
        let plain = ConformEngine.conformVideoArgs(source: h264, target: hevc)
        #expect(ConformEngine.conformVideoArgs(source: h264, target: hevc,
                                               damage: [], windowStart: 10, windowEnd: 50) == plain)
        #expect(ConformEngine.conformVideoArgs(
            source: h264, target: hevc,
            damage: [DamageZone(start: 60.0, end: 61.0, affectsVideo: true),
                     DamageZone(start: 5.0, end: 6.0, affectsVideo: true),
                     DamageZone(start: 24.0, end: 25.0, affectsVideo: false)],
            windowStart: 10, windowEnd: 50) == plain)
    }

    @Test func conformCountGateRelaxesOnlyForATruncatedEnding() {
        #expect(ConformEngine.eofShortfallAllowance(
            trimEnd: 999.6, fileEnd: 1000, targetFrameRate: "25/1") == 11)
        #expect(ConformEngine.eofShortfallAllowance(
            trimEnd: 990, fileEnd: 1000, targetFrameRate: "25/1") == 251)
        #expect(ConformEngine.eofShortfallAllowance(
            trimEnd: nil, fileEnd: 1000, targetFrameRate: "25/1") == 0)
        #expect(ConformEngine.eofShortfallAllowance(
            trimEnd: 999.6, fileEnd: nil, targetFrameRate: "25/1") == 0)
    }

    @Test func repairSelectKeepsTheWindowsFirstFrame() {
        #expect(ConformEngine.repairSelect(
            damage: [DamageZone(start: 9.8, end: 12.0, affectsVideo: true)],
            windowStart: 10.0, windowEnd: nil, sourceFrameRate: "25/1")
            == "select='not(between(t\\,0.03\\,2.01))'")
        #expect(ConformEngine.repairSelect(
            damage: [DamageZone(start: 24.0, end: 25.5, affectsVideo: true)],
            windowStart: nil, windowEnd: nil, sourceFrameRate: "25/1")
            == "select='not(between(t\\,23.99\\,25.51))'")
    }
}
