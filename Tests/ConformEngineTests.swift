import Testing
import Foundation
@testable import ClipStitcher

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

    /// A conform piece joining **deep** copy pieces keeps the encoder's default B-pyramid
    /// (ADR-0026): its container declares the join's reorder depth, and an MKV latches that
    /// from the first piece, so a shallower conform in front of a depth-2 copy is read with
    /// duplicate timestamps (issue #106). The shallow default — every join whose copies are
    /// shallow, and every non-MKV output, where depth is per frame anyway — keeps the
    /// pyramid-free command this engine has always produced.
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
        // Depth 1 is the default, so today's shallow commands are byte-identical.
        #expect(ConformEngine.conformVideoArgs(source: h264, target: hevc, reorderDepth: 1)
            == ConformEngine.conformVideoArgs(source: h264, target: hevc))
        // An MPEG-2 target has no pyramid either way.
        #expect(ConformEngine.conformVideoArgs(source: hevc, target: mpeg2, reorderDepth: 2)
            == ConformEngine.conformVideoArgs(source: hevc, target: mpeg2))
    }

    /// The conform CRF knob (issue #105 follow-up): an explicit CRF lands as the `-crf`
    /// wrapper flag on both x264 and x265 (de-risked in the shell on both encoders ×
    /// all three piece containers, alongside the params flags), an MPEG-2 target
    /// ignores it (no CRF rate control), and the nil default keeps every command
    /// byte-identical to before the knob existed.
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

    /// An unrecognised target profile is omitted rather than guessed — a wrong `-profile:v`
    /// token aborts the encode, and the encoder infers a profile from the pixel format.
    @Test func unmappedProfileIsDropped() {
        var weird = h264; weird.profile = "Some Exotic Profile"
        let args = ConformEngine.conformVideoArgs(source: hevc, target: weird)
        #expect(!args.contains("-profile:v"))
        #expect(args.contains("libx264") && args.contains("-level"))
    }

    // MARK: color conversion toward a tagged target (issue #35)

    /// The France 2005 target as probed: a *hybrid* triple — bt709 primaries/transfer but a
    /// bt470bg (BT.601) matrix — which is exactly why the conversion uses the individual
    /// space/primaries/trc options and never an `all=` preset.
    private let france = VideoProperties(
        codec: "h264", profile: "High", level: "51", width: 704, height: 576,
        frameRate: "50/1", pixelFormat: "yuv420p", fieldOrder: "progressive",
        sampleAspectRatio: "12:11", colorPrimaries: "bt709", colorTransfer: "bt709",
        colorSpace: "bt470bg", colorRange: "tv")

    /// Untagged SD → tagged target (shell leg A): the source's color is assumed BT.601
    /// 625-line (≤576 lines, 25 fps family), converted with both sides pinned explicitly,
    /// and the encoder writes the target triple into the VUI. The conversion sits after
    /// `format=` and before the fps tail, on progressive frames. Byte-exact to the
    /// shell-proven command.
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

    /// Untagged HD → tagged target (shell leg B): >576 lines assumes BT.709, and because the
    /// France target's *matrix* is bt470bg the assumed-709 source still genuinely converts —
    /// matching tags would have skipped instead.
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

    /// An untagged source whose *assumed* spec already equals the target's tags is tagged
    /// without conversion (shell leg E3): `setparams` pins the assumption on the frames so the
    /// encoder's color flags are an identity, never ffmpeg's own auto-conversion guess —
    /// pixels stay byte-identical (proven in the shell on a solid-color source).
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

    /// A fully-tagged source matching the target's tags passes the color stage untouched
    /// (no gratuitous conversion — shell leg E2): no color filter at all, only the VUI flags,
    /// which are an identity against the already-correct frame props.
    @Test func taggedSourceMatchingTargetSkipsTheColorStage() {
        #expect(ConformEngine.colorStage(source: france, target: france) == nil)
        var smaller = france; smaller.width = 352; smaller.height = 288
        let args = ConformEngine.conformVideoArgs(source: smaller, target: france)
        #expect(!args[1].contains("colorspace") && !args[1].contains("setparams"))
        #expect(args.suffix(6) == ["-color_primaries", "bt709", "-color_trc", "bt709",
                                   "-colorspace", "bt470bg"])
    }

    /// The untagged-source heuristic (issue #35): SD splits on the rate family — 625-line
    /// BT.601 for 25/50 fps, 525-line for 30000/1001-family — and anything over 576 lines
    /// is BT.709. BT.601's transfer probes as smpte170m in both variants.
    @Test func assumedColorTripleFollowsTheIndustryHeuristic() {
        #expect(ConformEngine.assumedColorTriple(height: 576, frameRate: "25/1")
            == ("bt470bg", "smpte170m", "bt470bg"))
        #expect(ConformEngine.assumedColorTriple(height: 480, frameRate: "30000/1001")
            == ("smpte170m", "smpte170m", "smpte170m"))
        #expect(ConformEngine.assumedColorTriple(height: 1080, frameRate: "50/1")
            == ("bt709", "bt709", "bt709"))
    }

    /// The assumption is surfaced to the user (issue #35 acceptance): named plainly when an
    /// untagged source converts toward a tagged target, silent when the source is fully
    /// tagged or the target imposes no complete spec.
    @Test func assumedColorWarningNamesTheAssumptionOnlyWhenUsed() {
        let warned = ConformEngine.assumedColorWarning(clipName: "Broadcast", source: mpeg2, target: france)
        #expect(warned?.contains("BT.601 (625-line)") == true && warned?.contains("Broadcast") == true)
        #expect(ConformEngine.assumedColorWarning(clipName: "f", source: france, target: france) == nil)
        #expect(ConformEngine.assumedColorWarning(clipName: "x", source: mpeg2, target: h264) == nil)
    }

    /// A target tagged on only part of the triple keeps the pre-#35 behavior: a converter
    /// can't aim at a partial spec, so no conversion and no VUI triple is emitted (the
    /// self-verify still flags the specified fields loudly).
    @Test func partiallyTaggedTargetGetsNoConversion() {
        var partial = h264; partial.colorPrimaries = "bt709"   // transfer/matrix unprobed
        let args = ConformEngine.conformVideoArgs(source: mpeg2, target: partial)
        #expect(!args[1].contains("colorspace") && !args.contains("-color_primaries"))
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

    /// The export-wide MP4 timescale (issue #24) pins the conform's track — without it
    /// the encoder-default 1/12800 collapses next to a copy piece at the concat.
    @Test func conformArgumentsCarryTheExportWideTimescaleWhenSet() {
        let pinned = ConformEngine.conformArguments(
            source: src, start: nil, end: nil, sourceVideo: hevc, targetVideo: mpeg2,
            output: out, trackTimescale: 450000)
        let i = pinned.firstIndex(of: "-video_track_timescale")
        #expect(i != nil && pinned[pinned.index(after: i!)] == "450000")
        // and without one the command keeps its validated shape
        let plain = ConformEngine.conformArguments(
            source: src, start: nil, end: nil, sourceVideo: hevc, targetVideo: mpeg2, output: out)
        #expect(!plain.contains("-video_track_timescale"))
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

    /// The gap-fill variant (issue #44): the de-risked defensive resample — `async=1`
    /// lays silence into timestamp gaps in place, `first_pts=0` anchors a window that
    /// starts inside a dead zone. Pinned so the shipped leg can't drift from the
    /// de-risked string (byte-identical to the plain conform on clean sources, #43).
    @Test func audioFilterGapFillMatchesTheDeRiskedString() {
        #expect(ConformEngine.audioFilter(sampleRate: 48000, channels: 2, fillGaps: true)
            == "aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo")
    }

    // MARK: channel mix (ADR-0019)

    /// The exact mix recipes validated in the shell (issue #38 de-risk, 2026-06) on
    /// MPEG-2/H.264/HEVC in TS/MKV/MP4 — pinned so the shipped command can't drift
    /// from the de-risked one.
    @Test func stereoSourceMixRecipesMatchTheDeRiskedStrings() {
        #expect(ConformEngine.mixFilter(.leftOnly, sourceChannels: 2)
            == "pan=stereo|c0=c0|c1=c0")
        #expect(ConformEngine.mixFilter(.rightOnly, sourceChannels: 2)
            == "pan=stereo|c0=c1|c1=c1")
        #expect(ConformEngine.mixFilter(.mono, sourceChannels: 2)
            == "pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1")
    }

    /// A surround source folds to stereo first (ffmpeg's standard fold-down — verified
    /// FL/FC/BL placement and dropped LFE on a synthesized 5.1); Left/Right/Mono then
    /// shape that stereo image.
    @Test func surroundSourceMixRecipesFoldDownFirst() {
        #expect(ConformEngine.mixFilter(.stereo, sourceChannels: 6)
            == "aformat=channel_layouts=stereo")
        #expect(ConformEngine.mixFilter(.leftOnly, sourceChannels: 6)
            == "aformat=channel_layouts=stereo,pan=stereo|c0=c0|c1=c0")
        #expect(ConformEngine.mixFilter(.mono, sourceChannels: 6)
            == "aformat=channel_layouts=stereo,pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1")
    }

    /// A no-op mix builds no filter at all — the leg stays byte-identical to a
    /// pre-#38 export.
    @Test func noOpMixesBuildNoFilter() {
        #expect(ConformEngine.mixFilter(.original, sourceChannels: 2) == nil)
        #expect(ConformEngine.mixFilter(.stereo, sourceChannels: 2) == nil)
        #expect(ConformEngine.mixFilter(.leftOnly, sourceChannels: 1) == nil)
        #expect(ConformEngine.mixFilter(.mono, sourceChannels: nil) == nil)
    }

    // MARK: damage repair in the conform chain (#48)

    /// Each zone in the kept window becomes a `select` drop sitting immediately before
    /// the fps stage, expressed relative to the window's seek (zone times and the
    /// window share the container-start base). Quarter-frame margins; recipe validated
    /// on all three formats × three containers in the shell.
    @Test func damageZonesBecomeASelectBeforeTheFpsStage() {
        let args = ConformEngine.conformVideoArgs(
            source: h264, target: hevc,
            damage: [DamageZone(start: 24.0, end: 25.5, affectsVideo: true)],
            windowStart: 10.0, windowEnd: 50.0)
        #expect(args[1] == "scale=1440:1080,pad=1920:1080:240:0,setsar=1/1,format=yuv420p10le,"
            + "select='not(between(t\\,13.99\\,15.51))',fps=50")
    }

    /// No zones — the chain is byte-identical to before repair existed; zones outside
    /// the kept window (or audio-only) drop no frames either.
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

    /// The conform's ±1 count gate relaxes only for a genuine **truncated ending** — a
    /// `trimEnd` decided upstream (`ExportPlanner.truncatedEndingTrim`), never re-derived from
    /// raw zones here (issue #79). The piece drops the trailing damaged span `[trimEnd, fileEnd)`
    /// and the container's claimed end can overshoot the last decodable frame (the 1844's TS
    /// headers do, by ~0.2 s), so the allowance is that span in frames plus one for the trim
    /// boundary. No truncated ending (`trimEnd` nil) keeps the ±1 gate exact — a real interior
    /// zone near an interior out point can no longer spuriously relax it (the old 1.0 s bug).
    @Test func conformCountGateRelaxesOnlyForATruncatedEnding() {
        // Trimmed at 999.6 with the file ending at 1000: (1000 − 999.6) × 25 + 1 = 11.
        #expect(ConformEngine.eofShortfallAllowance(
            trimEnd: 999.6, fileEnd: 1000, targetFrameRate: "25/1") == 11)
        // A deeper trailing span allows a deeper shortfall: (1000 − 990) × 25 + 1 = 251.
        #expect(ConformEngine.eofShortfallAllowance(
            trimEnd: 990, fileEnd: 1000, targetFrameRate: "25/1") == 251)
        // No truncated ending: exact ±1 gate, whatever the file end.
        #expect(ConformEngine.eofShortfallAllowance(
            trimEnd: nil, fileEnd: 1000, targetFrameRate: "25/1") == 0)
        // No known file end: exact gate.
        #expect(ConformEngine.eofShortfallAllowance(
            trimEnd: 999.6, fileEnd: nil, targetFrameRate: "25/1") == 0)
    }

    /// A zone reaching back to (or past) the window start is clamped so the window's
    /// first frame survives as the fps fill's hold material — a glitched held frame
    /// beats a shifted timeline. An open window start anchors at 0.
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
