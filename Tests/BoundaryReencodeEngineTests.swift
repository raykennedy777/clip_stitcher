import Testing
import Foundation
@testable import ClipStitcher

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
            == ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18"])
    }

    @Test func hevcReencodesWithLibx265Keeping10Bit() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "hevc", pixelFormat: "yuv420p10le", fieldOrder: "unknown")
            == ["-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-crf", "18"])
    }

    @Test func mpeg2ReencodesInterlacedTopFieldFirst() {
        // ffmpeg carries SAR through automatically, so no -aspect is needed; the
        // interlace flags preserve field_order=tt (verified in the shell).
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "mpeg2video", pixelFormat: "yuv420p", fieldOrder: "tt", bitrate: 2_530_995)
            == ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p", "-flags", "+ildct+ilme", "-top", "1",
                "-b:v", "3163744", "-maxrate", "4745616", "-bufsize", "6327488"])
    }

    @Test func progressiveMpeg2HasNoInterlaceFlags() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "mpeg2video", pixelFormat: "yuv420p", fieldOrder: "progressive",
            bitrate: 2_530_995)
            == ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p",
                "-b:v", "3163744", "-maxrate", "4745616", "-bufsize", "6327488"])
    }

    // MARK: rate control (issue #110)

    /// Every piece built from these args carries explicit rate control at a fixed
    /// near-lossless constant — without it each encoder used its *own* default (CRF 28 on
    /// libx265, 23 on libx264), so a boundary re-encode shipped at half the bitrate of the
    /// copy pieces beside it. A codec with no encoder entry re-encodes as H.264
    /// (`EncoderSelection.encoder`), so it takes the same CRF.
    @Test func crfCapableFamiliesTakeTheFixedNearLosslessCrf() {
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "h264", bitrate: nil)
            == ["-crf", "18"])
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "hevc", bitrate: 40_000_000)
            == ["-crf", "18"])   // a known bitrate changes nothing on a CRF-capable encoder
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "vp9", bitrate: nil)
            == ["-crf", "18"])
    }

    /// mpeg2video has no CRF mode, so it targets the source's own measured bitrate plus
    /// deliberate headroom (re-encoding decoded frames is less efficient than the original
    /// encode), with `-maxrate`/`-bufsize` bounding the peaks at 1.5× and 2× the target.
    @Test func mpeg2TargetsTheSourceBitrateWithHeadroom() {
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "mpeg2video", bitrate: 4_000_000)
            == ["-b:v", "5000000", "-maxrate", "7500000", "-bufsize", "10000000"])
    }

    /// An unmeasurable source bitrate (unreadable probe, damaged file) falls back to a fixed
    /// low quantiser — bigger than the source but never a quality regression, and the export
    /// still completes. Never back to the encoder's 200 kbps default.
    @Test func mpeg2FallsBackToAFixedQuantiserWhenNoBitrateIsKnown() {
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "mpeg2video", bitrate: nil)
            == ["-q:v", "2"])
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "mpeg2video", bitrate: 0)
            == ["-q:v", "2"])
    }

    /// The PAFF damage-to-EOF repair keeps its own pinned `-crf 18` recipe (issue #54),
    /// untouched by the rate control the source-matched builder now adds.
    @Test func theFieldCodedRepairRecipeIsUnchanged() {
        let args = BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: "tt")
        #expect(args.filter { $0 == "-crf" }.count == 1)
        #expect(!args.contains("-q:v"))
        #expect(!args.contains("-b:v"))
    }

    // MARK: source-profile matching (ADR-0009)

    /// A recognised source profile is pinned with `-profile:v` so an unusual source still
    /// matches — e.g. a Baseline H.264 clip that the encoder would otherwise lift to High.
    @Test func aKnownSourceProfileIsMatchedExplicitly() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "h264", profile: "Baseline", pixelFormat: "yuv420p", fieldOrder: "progressive")
            == ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "baseline", "-crf", "18"])
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "hevc", profile: "Main 10", pixelFormat: "yuv420p10le", fieldOrder: "unknown")
            == ["-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-profile:v", "main10", "-crf", "18"])
        // The profile arg precedes the interlace flags for MPEG-2, and the rate control
        // closes the array — the exact order de-risked in the shell.
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "mpeg2video", profile: "Main", pixelFormat: "yuv420p", fieldOrder: "tt")
            == ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p", "-profile:v", "main",
                "-flags", "+ildct+ilme", "-top", "1", "-q:v", "2"])
    }

    /// An unrecognised profile is omitted rather than guessed (a wrong token aborts the
    /// encode); the encoder then infers a profile from the pixel format, which matches the
    /// source for every common case.
    @Test func anUnknownProfileIsOmittedNotGuessed() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "h264", profile: "Some Exotic Profile", pixelFormat: "yuv420p", fieldOrder: "progressive")
            == ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18"])
        #expect(EncoderSelection.encoderProfile(nil, codec: "h264") == nil)
        #expect(EncoderSelection.encoderProfile("Main 10", codec: "mpeg2video") == nil)
    }

    // MARK: head/tail re-encode

    /// Re-encodes a partial-GOP range by input-seeking to the keyframe at/before the
    /// range start (so only ~one GOP decodes, not the whole file) and selecting frames
    /// RELATIVE to that keyframe — which the decoder emits as n=0 after the seek. The
    /// seek is start_time-relative (the stream starts at 0.24 here), so the first
    /// presentation PTS is subtracted.
    ///
    /// `-frames:v <range.count>` is the run's stop condition: `select` alone keeps
    /// ffmpeg decoding from the range's end to the file's end, emitting nothing — a
    /// 72-minute source pinned the CPU for minutes after a 28 s cut and froze the
    /// progress bar (test_sprint diagnosis). The frame budget ends the run at the last
    /// kept frame (1 s instead of ≥25 s on the real footage, identical output).
    @Test func reencodeSegmentSeeksToKeyframeAndSelectsRelativeFrames() {
        // 8 frames starting at 0.24; keyframes at 0 and 4.
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        // Tail range [6,8): frames 6,7. Keyframe at/before 6 is 4; seek = 0.40-0.24 = 0.16;
        // relative select between 6-4=2 and 7-4=3; stop after the 2 kept frames.
        let args = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 6..<8, index: index,
            encoder: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], output: out)
        #expect(args == [
            "-v", "error", "-ss", "0.16", "-i", src.path,
            "-vf", "select='between(n\\,2\\,3)',setpts=PTS-STARTPTS",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-frames:v", "2", "-an", out.path,
        ])
    }

    /// #18: an MP4 piece must carry the same video track timescale as the stream-copied
    /// pieces it concats with — the concat demuxer reads every listed file in one timebase,
    /// and the encoder-default 1/12800 track otherwise lands mis-scaled next to a
    /// source-inherited 1/25000 copy piece, collapsing the re-encode's frames when the mp4
    /// muxer "repairs" the resulting non-monotonic DTS (verified in the shell, all 3 codecs).
    @Test func anMp4ReencodePieceCarriesTheSourceTrackTimescale() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let mp4Piece = URL(fileURLWithPath: "/tmp/seg.mp4")
        let args = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 6..<8, index: index,
            encoder: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], output: mp4Piece,
            trackTimescale: 25000)
        #expect(args == [
            "-v", "error", "-ss", "0.16", "-i", src.path,
            "-vf", "select='between(n\\,2\\,3)',setpts=PTS-STARTPTS",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-video_track_timescale", "25000",
            "-frames:v", "2", "-an", mp4Piece.path,
        ])
    }

    /// The timescale pin is mp4-only and never guessed: MKV/TS impose a fixed
    /// per-container timebase (1/1000, 1/90000) so every piece already matches there,
    /// and an unknown source timescale omits the flag rather than inventing one.
    @Test func trackTimescaleIsOmittedOffMp4AndWhenUnknown() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let mkvArgs = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 6..<8, index: index,
            encoder: ["-c:v", "libx264"], output: URL(fileURLWithPath: "/tmp/seg.mkv"),
            trackTimescale: 25000)
        #expect(!mkvArgs.contains("-video_track_timescale"))
        let unknownArgs = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 6..<8, index: index,
            encoder: ["-c:v", "libx264"], output: URL(fileURLWithPath: "/tmp/seg.mp4"),
            trackTimescale: nil)
        #expect(!unknownArgs.contains("-video_track_timescale"))
    }

    /// The timescale is measured, never derived from the source container: a one-packet
    /// stream-copy probe piece is muxed to MP4 and its track timescale read back. Source
    /// timebases don't map 1:1 — the mp4 muxer auto-raises an MKV's coarse 1/1000 stream
    /// timebase to 1/16000 on copy (verified in the shell), so only the muxer's own
    /// output answers what the copy pieces will carry.
    @Test func timescaleProbeCopiesOnePacketToMp4() {
        let probe = URL(fileURLWithPath: "/tmp/c0_tsprobe.mp4")
        #expect(BoundaryReencodeEngine.timescaleProbeArguments(source: src, output: probe) == [
            "-v", "error", "-i", src.path, "-map", "0:v:0",
            "-c", "copy", "-frames:v", "1", probe.path,
        ])
    }

    /// The flag's value comes from the probe piece's `time_base` ("1/16000" ⇒ 16000).
    /// Only a unit-numerator timebase maps to an MP4 track timescale; anything else
    /// (or an unparsable/absent probe) yields nil so the flag is omitted rather than
    /// guessed.
    @Test func trackTimescaleParsesTheProbedTimeBaseDenominator() {
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "1/25000") == 25000)
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "1/90000") == 90000)
        // ffprobe's csv writer emits a trailing comma on MPEG-2 streams ("1/90000,").
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "1/90000,") == 90000)
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: nil) == nil)
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "1001/30000") == nil)
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "1/0") == nil)
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "garbage") == nil)
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
        let plan = BoundaryReencodeEngine.copySegmentPlan(
            copyRange: 4..<7, outCutKeyframe: 7, index: index)
        #expect(abs((plan.inSegmentTime ?? -1) - 0.14) < 1e-9)   // (0.36+0.40)/2 - 0.24
        #expect(abs((plan.outSegmentTime ?? -1) - 0.26) < 1e-9)  // (0.48+0.52)/2 - 0.24
        #expect(ExportEngine.wantedSegmentIndex(plan: plan) == 1)
        #expect(ExportEngine.needsCut(plan))
    }

    /// #16: the out-cut anchors at the plan's cut *keyframe*, not the copy range's end.
    /// On an open-GOP end the range stops `n_leading` frames early (those slots re-encode),
    /// but the muxer cut time still derives from the keyframe's DTS midpoint — the cut
    /// before the keyframe is what sends its leading pictures to the discarded segment.
    @Test func outCutTimeComesFromTheCutKeyframeNotTheRangeEnd() {
        // Presentation: 0..3 previous GOP, 4..5 leading pictures (decode after 6), 6 the
        // open keyframe (CRA), 7 a trailing frame.
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            dts: [0.20, 0.24, 0.28, 0.32, 0.48, 0.52, 0.44, 0.56],
            keyframeFlags: [true, false, false, false, false, false, true, false])
        let plan = BoundaryReencodeEngine.copySegmentPlan(
            copyRange: 0..<4, outCutKeyframe: 6, index: index)
        // Midpoint of the keyframe's DTS (0.44) and its decode predecessor (0.32),
        // start_time-corrected: (0.32+0.44)/2 - 0.24 = 0.14.
        #expect(plan.inSegmentTime == nil)
        #expect(abs((plan.outSegmentTime ?? -1) - 0.14) < 1e-9)
    }

    /// A copy that runs to the file end needs no out-cut, and one from the file start
    /// needs no in-cut — so a whole-clip copy is a plain remux (M1 behaviour reused).
    @Test func copySegmentOmitsCutsAtClipBoundaries() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, true])
        let whole = BoundaryReencodeEngine.copySegmentPlan(
            copyRange: 0..<8, outCutKeyframe: nil, index: index)
        #expect(whole.inSegmentTime == nil && whole.outSegmentTime == nil)
        #expect(!ExportEngine.needsCut(whole))

        let toEnd = BoundaryReencodeEngine.copySegmentPlan(
            copyRange: 4..<8, outCutKeyframe: nil, index: index)
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

    // MARK: repaired segments (#47)

    /// 25 fps with a keyframe every 25 frames — the shape of the de-risked fixtures
    /// (issue #43/#47 shell runs).
    private func cleanIndex(count: Int = 200, gop: Int = 25, firstPts: Double = 0) -> FrameIndex {
        FrameIndex(pts: (0..<count).map { firstPts + Double($0) * 0.04 },
                   keyframeFlags: (0..<count).map { $0 % gop == 0 })
    }

    /// The repaired re-encode selects by **time**, not frame number (the index↔decoder
    /// numbering drifts at truncated packets): the seek lands one keyframe before the
    /// span's own anchor (a truncated final GOP decodes nothing when entered directly —
    /// #47 de-risk), the select keeps the span and drops each zone's window
    /// (quarter-frame margins), and `fps` at the source rate fills the dropped span
    /// with the held frame. `-frames:v` is the span's slot budget — it bounds the run
    /// and truncates the fps EOF fill exactly at the span end.
    @Test func repairedSegmentSelectsByTimeDroppingZones() {
        // Range [100,150): T0=4.0, T1=6.0. Anchor: keyframe at 100, one back → 75 (3.0 s).
        let args = BoundaryReencodeEngine.repairedSegmentArguments(
            source: src, range: 100..<150, index: cleanIndex(),
            zones: [DamageZone(start: 4.5, end: 5.0, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1",
            encoder: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], output: out)
        #expect(args == [
            "-v", "error", "-ss", "3", "-t", "4", "-i", src.path,
            "-vf", "select='between(t\\,0.99\\,2.97)*not(between(t\\,1.49\\,2.01))'"
                + ",setpts=PTS-STARTPTS,fps=25",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-frames:v", "50", "-an", out.path,
        ])
    }

    /// MPEG-PS time-seek is byte-estimated and lands late, badly so near damage
    /// (issue #43 de-risk) — a `.mpg` source seeks **two** keyframes back instead of
    /// one; the span bound in the select discards the extra lead-in either way.
    @Test func repairedSegmentSeeksTwoKeyframesBackOnMpegPS() {
        let mpg = URL(fileURLWithPath: "/clips/in.mpg")
        // PS shape: start_time 0.54, GOP 15 (0.6 s). Range [60,90): T0 = 2.94 abs.
        let index = cleanIndex(count: 120, gop: 15, firstPts: 0.54)
        let args = BoundaryReencodeEngine.repairedSegmentArguments(
            source: mpg, range: 60..<90, index: index,
            zones: [DamageZone(start: 2.6, end: 3.0, affectsVideo: true)],
            containerStart: 0.54, frameRate: "25/1",
            encoder: ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p"], output: out)
        // Anchor: keyframe 60, two back → 30 (pts 1.74, seek 1.2). Span rel [1.19, 2.37],
        // zone rel (1.39, 1.81). Budget 30 = the 1.2 s span at 25 fps.
        #expect(args == [
            "-v", "error", "-ss", "1.2", "-t", "3.4", "-i", mpg.path,
            "-vf", "select='between(t\\,1.19\\,2.37)*not(between(t\\,1.39\\,1.81))'"
                + ",setpts=PTS-STARTPTS,fps=25",
            "-c:v", "mpeg2video", "-pix_fmt", "yuv420p",
            "-frames:v", "30", "-an", out.path,
        ])
    }

    /// A zone reaching back to (or past) the span start would leave `fps` nothing to
    /// hold — the window is clamped so the span's first frame is always kept, even
    /// when it is itself damaged: a glitched held frame beats a shifted timeline.
    @Test func repairedSegmentKeepsTheSpansFirstFrame() {
        let args = BoundaryReencodeEngine.repairedSegmentArguments(
            source: src, range: 100..<150, index: cleanIndex(),
            zones: [DamageZone(start: 3.8, end: 4.5, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1",
            encoder: ["-c:v", "libx264"], output: out)
        let vf = args[args.firstIndex(of: "-vf")! + 1]
        // The raw window start (rel 0.79) would swallow the span head; the clamp holds
        // it one frame past the span start so the frame at rel 1.0 survives as the hold.
        #expect(vf.contains("not(between(t\\,1.03\\,1.51))"))
    }

    /// An MP4 repaired piece pins the track timescale like any re-encoded piece (#18/#24).
    @Test func anMp4RepairedPieceCarriesTheTrackTimescale() {
        let mp4Piece = URL(fileURLWithPath: "/tmp/seg.mp4")
        let args = BoundaryReencodeEngine.repairedSegmentArguments(
            source: src, range: 100..<150, index: cleanIndex(),
            zones: [DamageZone(start: 4.5, end: 5.0, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1",
            encoder: ["-c:v", "libx264"], output: mp4Piece, trackTimescale: 25000)
        #expect(args.firstIndex(of: "-video_track_timescale") != nil)
    }

    /// A repaired span's frame count is its slot budget — duration × fps, exact: holes
    /// are filled, corrupt frames dropped and held over, and the fps fill always
    /// reaches the budget interior (the span's right boundary is a clean keyframe that
    /// decodes, and the fill pads to the last decoded frame — #47 de-risk).
    @Test func repairedExpectationIsTheSpanSlotBudget() {
        let e = BoundaryReencodeEngine.repairedSegmentExpectation(
            range: 100..<150, index: cleanIndex(),
            zones: [DamageZone(start: 4.5, end: 5.0, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1")
        #expect(e.frames == 50)
        #expect(e.shortfallAllowance == 0)
    }

    /// A damage window running through the **file end** is a truncated ending: it has
    /// nothing after it to keep in sync, so the repair *trims* to the last complete frame
    /// rather than fps-filling the dropped slots (issue #79, CONTEXT.md "Repair"). The
    /// budget is capped at the frames before the zone's start — the sole trim exception to
    /// repair's length preservation — so the piece simply ends there.
    @Test func repairedExpectationTrimsAtAnEofTruncatedEnding() {
        let index = cleanIndex(count: 100)   // ends at pts 3.96, T1 = 4.0
        let e = BoundaryReencodeEngine.repairedSegmentExpectation(
            range: 75..<100, index: index,
            zones: [DamageZone(start: 3.5, end: 4.1, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1")
        // Span [3.0, 4.0); the trailing zone starts at 3.5, so the piece is trimmed to the
        // 13 frames from 3.0 up to 3.5 (0.5 s × 25) instead of the full 25-slot budget.
        #expect(e.frames == 13)
        #expect(e.shortfallAllowance == 0)
    }

    /// The allowance is EOF-only: a mid-file zone at the range's tail still fills to
    /// budget (the data past the span decodes), and an EOF range whose zone ends before
    /// the final slot leaves no trailing uncertainty.
    @Test func shortfallAllowanceIsZeroOffTheEofWindow() {
        // Same zone, but the range stops before the file end.
        #expect(BoundaryReencodeEngine.repairedSegmentExpectation(
            range: 75..<100, index: cleanIndex(count: 150),
            zones: [DamageZone(start: 3.5, end: 4.1, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1").shortfallAllowance == 0)
        // EOF range, interior zone.
        #expect(BoundaryReencodeEngine.repairedSegmentExpectation(
            range: 75..<100, index: cleanIndex(count: 100),
            zones: [DamageZone(start: 3.2, end: 3.5, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1").shortfallAllowance == 0)
    }

    // MARK: - Truncated-ending trim (issue #79)

    /// A truncated ending — a video zone reaching the file end — trims the slot budget to the
    /// frames before it, so the repaired piece ends on the last complete frame instead of the
    /// `fps` fill padding the dropped final slot to the full budget (CONTEXT.md "Repair").
    @Test func trimmedSlotBudgetCapsAtATruncatedEnding() {
        let index = cleanIndex(count: 100)   // pts 0…3.96, spanEnd 4.0
        // EOF span [3.0, 4.0); the trailing zone runs from 3.7 to the end.
        let budget = BoundaryReencodeEngine.trimmedSlotBudget(
            range: 75..<100, index: index,
            zones: [DamageZone(start: 3.7, end: 4.05, affectsVideo: true)],
            fps: 25, containerStart: 0)
        #expect(budget == 18)   // (3.7 − 3.0) × 25, trimmed from the full 25
    }

    /// The trim is EOF-only: an interior span (not reaching the file end) keeps its full slot
    /// budget and fps-fills as before — length preserved everywhere except a true file-end.
    @Test func trimmedSlotBudgetIsFullForAnInteriorSpan() {
        let index = cleanIndex(count: 200)
        #expect(BoundaryReencodeEngine.trimmedSlotBudget(
            range: 100..<150, index: index,
            zones: [DamageZone(start: 4.5, end: 5.0, affectsVideo: true)],
            fps: 25, containerStart: 0) == 50)
        // An EOF span whose zone ends before the final slot is not a truncated ending either.
        #expect(BoundaryReencodeEngine.trimmedSlotBudget(
            range: 75..<100, index: cleanIndex(count: 100),
            zones: [DamageZone(start: 3.2, end: 3.5, affectsVideo: true)],
            fps: 25, containerStart: 0) == 25)
    }

    /// End to end through the argument builder: an EOF truncated ending emits the trimmed
    /// `-frames:v`, so ffmpeg stops on the last complete frame.
    @Test func repairedSegmentArgumentsTrimFramesVAtEof() {
        let args = BoundaryReencodeEngine.repairedSegmentArguments(
            source: src, range: 75..<100, index: cleanIndex(count: 100),
            zones: [DamageZone(start: 3.7, end: 4.05, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1",
            encoder: ["-c:v", "libx264"], output: out)
        let fv = args.firstIndex(of: "-frames:v").map { args[$0 + 1] }
        #expect(fv == "18")
    }

    // MARK: - Bounded keyframe copy (Clip Doctor repair-only export, #52)

    /// 10 frames at 25 fps starting at the container's 1.0 s start_time.
    private var boundedCopyIndex: FrameIndex {
        let pts = (0..<10).map { 1.0 + Double($0) * 0.04 }
        return FrameIndex(pts: pts, keyframeFlags: Array(repeating: true, count: 10))
    }

    @Test func boundedCopySeeksToTheSpanAndSplitsAfterItsFrameCount() {
        let args = BoundaryReencodeEngine.boundedCopyArguments(
            source: src, range: 2..<6, index: boundedCopyIndex, containerStart: 1.0,
            segmentPattern: "/tmp/cp_%03d.ts")
        // Input seek is start_time-relative: pts[2] (1.08) − containerStart (1.0) = 0.08.
        #expect(args[args.firstIndex(of: "-ss")! + 1] == "0.08")
        #expect(args.firstIndex(of: "-ss")! < args.firstIndex(of: "-i")!)   // input seek
        // A single split after exactly hi−lo = 4 frames → segment 000 is the span.
        #expect(args[args.firstIndex(of: "-segment_frames")! + 1] == "4")
        #expect(args.contains("-reset_timestamps"))
        // The read is bounded a couple of seconds past the span, not run to EOF.
        #expect(args[args.firstIndex(of: "-t")! + 1] == "2.16")   // span 0.16 + 2.0
        #expect(args.contains("-c") && args.contains("copy") && args.contains("0:v:0"))
        #expect(args.last == "/tmp/cp_%03d.ts")
    }

    @Test func boundedCopyOfTheFirstSpanSeeksToZero() {
        let args = BoundaryReencodeEngine.boundedCopyArguments(
            source: src, range: 0..<4, index: boundedCopyIndex, containerStart: 1.0,
            segmentPattern: "/tmp/cp_%03d.ts")
        #expect(args[args.firstIndex(of: "-ss")! + 1] == "0")
        #expect(args[args.firstIndex(of: "-segment_frames")! + 1] == "4")
    }

    @Test func boundedCopyOfTheTailRunsToTheLastFrame() {
        // hi == count: span end is the last frame's pts, frame count is count − lo.
        let args = BoundaryReencodeEngine.boundedCopyArguments(
            source: src, range: 6..<10, index: boundedCopyIndex, containerStart: 1.0,
            segmentPattern: "/tmp/cp_%03d.ts")
        #expect(args[args.firstIndex(of: "-segment_frames")! + 1] == "4")
    }

    // MARK: - Progress expectation for a bounded segment-muxer run (issue #107)

    /// The progress bar smooths a run by ffmpeg's `out_time` against how long that run's
    /// output is expected to be. A segment-muxer cut used to read the source to EOF, so
    /// the whole source span was the honest expectation; now an out-cut bounds the read
    /// (`cutArguments`), and the run ends at the out-cut plus the read margin — expecting
    /// the whole span would park the bar at a fraction of the segment and jump.
    @Test func aBoundedCutExpectsOnlyTheReadItWillActuallyDo() {
        let plan = SegmentPlan(inFrame: 100, outFrame: 1999, inSegmentTime: 4.0, outSegmentTime: 80.0)
        #expect(BoundaryReencodeEngine.segmentMuxExpectedSeconds(plan: plan, sourceSpan: 16_560.0) == 82.0)
    }

    @Test func anUnboundedCutStillExpectsTheWholeSourceSpan() {
        // No out-cut → the read runs to EOF, exactly as before, so does the expectation.
        let plan = SegmentPlan(inFrame: 100, outFrame: 1999, inSegmentTime: 4.0, outSegmentTime: nil)
        #expect(BoundaryReencodeEngine.segmentMuxExpectedSeconds(plan: plan, sourceSpan: 16_560.0) == 16_560.0)
        // An unmeasurable span stays unmeasurable (the bar then holds, it doesn't smooth).
        #expect(BoundaryReencodeEngine.segmentMuxExpectedSeconds(plan: plan, sourceSpan: nil) == nil)
    }

    @Test func theReadMarginNeverPushesTheExpectationPastTheSource() {
        // An out-cut within a margin of EOF: the read stops at EOF, so the expectation does.
        let plan = SegmentPlan(inFrame: 0, outFrame: 10, inSegmentTime: nil, outSegmentTime: 11.5)
        #expect(BoundaryReencodeEngine.segmentMuxExpectedSeconds(plan: plan, sourceSpan: 12.0) == 12.0)
    }

    // MARK: - MBAFF field-coded tail encoder (issue #54)

    /// `-top` follows the source scan order: top-field-first stays 1, bottom-field-first 0.
    @Test func mbaffRepairArgsCarryTheInterlaceFlagsCrf18AndTopFromFieldOrder() {
        let tff = BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: "tt")
        #expect(tff.contains("libx264"))
        #expect(tff[tff.firstIndex(of: "-flags")! + 1] == "+ildct+ilme")
        #expect(tff[tff.firstIndex(of: "-top")! + 1] == "1")
        #expect(tff[tff.firstIndex(of: "-crf")! + 1] == "18")        // fixed, visually lossless
        #expect(tff[tff.firstIndex(of: "-forced-idr")! + 1] == "1")  // clean IDR entry seam
        let params = tff[tff.firstIndex(of: "-x264-params")! + 1]
        #expect(params.contains("ref=5") && params.contains("open_gop=0") && params.contains("b-pyramid=0"))
        #expect(tff[tff.firstIndex(of: "-bsf:v")! + 1] == "dump_extra")

        let bff = BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: "bb")
        #expect(bff[bff.firstIndex(of: "-top")! + 1] == "0")
    }
}
