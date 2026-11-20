import Testing
import Foundation
@testable import ClipStitcher

struct BoundaryReencodeEngineTests {
    private let src = URL(fileURLWithPath: "/clips/in.ts")
    private let out = URL(fileURLWithPath: "/tmp/seg.ts")

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
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "mpeg2video", pixelFormat: "yuv420p", fieldOrder: "tt", bitrate: 2_530_995)
            == ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p", "-flags", "+ildct+ilme",
                "-b:v", "3163744", "-maxrate", "4745616", "-bufsize", "6327488",
                "-vf", "setparams=field_mode=tff"])
    }

    @Test func interlacedH264ReencodesInterlacedInTheSourcesDirection() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "h264", pixelFormat: "yuv420p", fieldOrder: "tt")
            == ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-flags", "+ildct+ilme", "-crf", "18",
                "-vf", "setparams=field_mode=tff"])
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(codec: "h264", pixelFormat: "yuv420p", fieldOrder: "bt")
            == BoundaryReencodeEngine.reencodeVideoArgs(codec: "h264", pixelFormat: "yuv420p", fieldOrder: "bb"))
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "hevc", pixelFormat: "yuv420p10le", fieldOrder: "tt")
            == ["-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-crf", "18"])
    }

    @Test func progressiveMpeg2HasNoInterlaceFlags() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "mpeg2video", pixelFormat: "yuv420p", fieldOrder: "progressive",
            bitrate: 2_530_995)
            == ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p",
                "-b:v", "3163744", "-maxrate", "4745616", "-bufsize", "6327488"])
    }

    @Test func aSegmentBuilderMergesTheEncodersScanFilterIntoItsOwnChain() {
        let index = FrameIndex(
            pts: [0.0, 0.04, 0.08, 0.12, 0.16, 0.20, 0.24, 0.28],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let boundary = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 4..<8, index: index,
            encoder: BoundaryReencodeEngine.reencodeVideoArgs(
                codec: "mpeg2video", pixelFormat: "yuv420p", fieldOrder: "tt"),
            output: out)
        #expect(boundary.filter { $0 == "-vf" }.count == 1)
        let boundaryChain = boundary[boundary.firstIndex(of: "-vf")! + 1]
        #expect(boundaryChain.hasPrefix("select="))
        #expect(boundaryChain.hasSuffix(",setparams=field_mode=tff"))

        let repaired = BoundaryReencodeEngine.repairedSegmentArguments(
            source: src, range: 4..<8, index: index, zones: [], containerStart: 0,
            frameRate: "25/1",
            encoder: BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: "bb"),
            output: out)
        #expect(repaired.filter { $0 == "-vf" }.count == 1)
        #expect(repaired[repaired.firstIndex(of: "-vf")! + 1]
            .hasSuffix(",setparams=field_mode=bff"))
    }

    @Test func aProgressiveEncoderLeavesTheChainUntouched() {
        let index = FrameIndex(
            pts: [0.0, 0.04, 0.08, 0.12, 0.16, 0.20, 0.24, 0.28],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let encoder = BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "h264", pixelFormat: "yuv420p", fieldOrder: "progressive")
        #expect(!encoder.contains("-vf"))
        let (filter, args) = BoundaryReencodeEngine.splitVideoFilter(encoder)
        #expect(filter == nil)
        #expect(args == encoder)
        let boundary = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 4..<8, index: index, encoder: encoder, output: out)
        #expect(!boundary[boundary.firstIndex(of: "-vf")! + 1].contains("setparams"))
    }

    @Test func crfCapableFamiliesTakeTheFixedNearLosslessCrf() {
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "h264", bitrate: nil)
            == ["-crf", "18"])
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "hevc", bitrate: 40_000_000)
            == ["-crf", "18"])
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "vp9", bitrate: nil)
            == ["-crf", "18"])
    }

    @Test func mpeg2TargetsTheSourceBitrateWithHeadroom() {
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "mpeg2video", bitrate: 4_000_000)
            == ["-b:v", "5000000", "-maxrate", "7500000", "-bufsize", "10000000"])
    }

    @Test func mpeg2FallsBackToAFixedQuantiserWhenNoBitrateIsKnown() {
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "mpeg2video", bitrate: nil)
            == ["-q:v", "2"])
        #expect(BoundaryReencodeEngine.rateControlArgs(codec: "mpeg2video", bitrate: 0)
            == ["-q:v", "2"])
    }

    @Test func theFieldCodedRepairRecipeIsUnchanged() {
        let args = BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: "tt")
        #expect(args.filter { $0 == "-crf" }.count == 1)
        #expect(!args.contains("-q:v"))
        #expect(!args.contains("-b:v"))
    }

    @Test func aKnownSourceProfileIsMatchedExplicitly() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "h264", profile: "Baseline", pixelFormat: "yuv420p", fieldOrder: "progressive")
            == ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "baseline", "-crf", "18"])
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "hevc", profile: "Main 10", pixelFormat: "yuv420p10le", fieldOrder: "unknown")
            == ["-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-profile:v", "main10", "-crf", "18"])
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "mpeg2video", profile: "Main", pixelFormat: "yuv420p", fieldOrder: "tt")
            == ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p", "-profile:v", "main",
                "-flags", "+ildct+ilme", "-q:v", "2", "-vf", "setparams=field_mode=tff"])
    }

    @Test func anUnknownProfileIsOmittedNotGuessed() {
        #expect(BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "h264", profile: "Some Exotic Profile", pixelFormat: "yuv420p", fieldOrder: "progressive")
            == ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18"])
        #expect(EncoderSelection.encoderProfile(nil, codec: "h264") == nil)
        #expect(EncoderSelection.encoderProfile("Main 10", codec: "mpeg2video") == nil)
    }

    @Test func reencodeSegmentSeeksToKeyframeAndSelectsRelativeFrames() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let args = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 6..<8, index: index,
            encoder: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], output: out)
        #expect(args == [
            "-v", "error", "-ss", "0.16", "-i", src.path,
            "-vf", "select='between(n\\,2\\,3)',setpts=PTS-STARTPTS",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-bsf:v", "dump_extra",
            "-frames:v", "2", "-an", out.path,
        ])
    }

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
            "-bsf:v", "dump_extra",
            "-video_track_timescale", "25000",
            "-frames:v", "2", "-an", mp4Piece.path,
        ])
    }

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

    @Test func timescaleProbeCopiesOnePacketToMp4() {
        let probe = URL(fileURLWithPath: "/tmp/c0_tsprobe.mp4")
        #expect(BoundaryReencodeEngine.timescaleProbeArguments(source: src, output: probe) == [
            "-v", "error", "-i", src.path, "-map", "0:v:0",
            "-c", "copy", "-frames:v", "1", probe.path,
        ])
    }

    @Test func trackTimescaleParsesTheProbedTimeBaseDenominator() {
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "1/25000") == 25000)
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "1/90000") == 90000)
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "1/90000,") == 90000)
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: nil) == nil)
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "1001/30000") == nil)
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "1/0") == nil)
        #expect(BoundaryReencodeEngine.trackTimescale(timeBase: "garbage") == nil)
    }

    @Test func copySegmentBecomesAnInteriorTwoCutPlan() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, true])
        let plan = BoundaryReencodeEngine.copySegmentPlan(
            copyRange: 4..<7, outCutKeyframe: 7, index: index)
        #expect(abs((plan.inSegmentTime ?? -1) - 0.14) < 1e-9)
        #expect(abs((plan.outSegmentTime ?? -1) - 0.26) < 1e-9)
        #expect(ExportEngine.wantedSegmentIndex(plan: plan) == 1)
        #expect(ExportEngine.needsCut(plan))
    }

    @Test func outCutTimeComesFromTheCutKeyframeNotTheRangeEnd() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            dts: [0.20, 0.24, 0.28, 0.32, 0.48, 0.52, 0.44, 0.56],
            keyframeFlags: [true, false, false, false, false, false, true, false])
        let plan = BoundaryReencodeEngine.copySegmentPlan(
            copyRange: 0..<4, outCutKeyframe: 6, index: index)
        #expect(plan.inSegmentTime == nil)
        #expect(abs((plan.outSegmentTime ?? -1) - 0.14) < 1e-9)
    }

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

    @Test func expectedFrameCountIsTheCombinedSegmentLength() {
        let plan = [
            PlannedSegment(kind: .reEncode, range: 3..<5),
            PlannedSegment(kind: .copy, range: 5..<10),
            PlannedSegment(kind: .reEncode, range: 10..<12),
        ]
        #expect(BoundaryReencodeEngine.expectedFrameCount(plan) == 9)
        #expect(BoundaryReencodeEngine.expectedFrameCount(
            [PlannedSegment(kind: .copy, range: 0..<100)]) == 100)
    }

    @Test func segmentSpansAreExactPresentationOffsetsLastIsNil() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let plan = [
            PlannedSegment(kind: .copy, range: 0..<4),
            PlannedSegment(kind: .reEncode, range: 4..<8),
        ]
        let spans = BoundaryReencodeEngine.segmentSpans(plan, index: index)
        #expect(spans.count == 2)
        #expect(abs((spans[0] ?? -1) - 0.16) < 1e-9)
        #expect(spans[1] == nil)
    }

    private func cleanIndex(count: Int = 200, gop: Int = 25, firstPts: Double = 0) -> FrameIndex {
        FrameIndex(pts: (0..<count).map { firstPts + Double($0) * 0.04 },
                   keyframeFlags: (0..<count).map { $0 % gop == 0 })
    }

    @Test func repairedSegmentSelectsByTimeDroppingZones() {
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
            "-bsf:v", "dump_extra",
            "-frames:v", "50", "-an", out.path,
        ])
    }

    @Test func repairedSegmentSeeksTwoKeyframesBackOnMpegPS() {
        let mpg = URL(fileURLWithPath: "/clips/in.mpg")
        let index = cleanIndex(count: 120, gop: 15, firstPts: 0.54)
        let args = BoundaryReencodeEngine.repairedSegmentArguments(
            source: mpg, range: 60..<90, index: index,
            zones: [DamageZone(start: 2.6, end: 3.0, affectsVideo: true)],
            containerStart: 0.54, frameRate: "25/1",
            encoder: ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p"], output: out)
        #expect(args == [
            "-v", "error", "-ss", "1.2", "-t", "3.4", "-i", mpg.path,
            "-vf", "select='between(t\\,1.19\\,2.37)*not(between(t\\,1.39\\,1.81))'"
                + ",setpts=PTS-STARTPTS,fps=25",
            "-c:v", "mpeg2video", "-pix_fmt", "yuv420p",
            "-bsf:v", "dump_extra",
            "-frames:v", "30", "-an", out.path,
        ])
    }

    @Test func repairedSegmentKeepsTheSpansFirstFrame() {
        let args = BoundaryReencodeEngine.repairedSegmentArguments(
            source: src, range: 100..<150, index: cleanIndex(),
            zones: [DamageZone(start: 3.8, end: 4.5, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1",
            encoder: ["-c:v", "libx264"], output: out)
        let vf = args[args.firstIndex(of: "-vf")! + 1]
        #expect(vf.contains("not(between(t\\,1.03\\,1.51))"))
    }

    @Test func anMp4RepairedPieceCarriesTheTrackTimescale() {
        let mp4Piece = URL(fileURLWithPath: "/tmp/seg.mp4")
        let args = BoundaryReencodeEngine.repairedSegmentArguments(
            source: src, range: 100..<150, index: cleanIndex(),
            zones: [DamageZone(start: 4.5, end: 5.0, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1",
            encoder: ["-c:v", "libx264"], output: mp4Piece, trackTimescale: 25000)
        #expect(args.firstIndex(of: "-video_track_timescale") != nil)
    }

    @Test func repairedExpectationIsTheSpanSlotBudget() {
        let e = BoundaryReencodeEngine.repairedSegmentExpectation(
            range: 100..<150, index: cleanIndex(),
            zones: [DamageZone(start: 4.5, end: 5.0, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1")
        #expect(e.frames == 50)
        #expect(e.shortfallAllowance == 0)
    }

    @Test func repairedExpectationTrimsAtAnEofTruncatedEnding() {
        let index = cleanIndex(count: 100)
        let e = BoundaryReencodeEngine.repairedSegmentExpectation(
            range: 75..<100, index: index,
            zones: [DamageZone(start: 3.5, end: 4.1, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1")
        #expect(e.frames == 13)
        #expect(e.shortfallAllowance == 0)
    }

    @Test func shortfallAllowanceIsZeroOffTheEofWindow() {
        #expect(BoundaryReencodeEngine.repairedSegmentExpectation(
            range: 75..<100, index: cleanIndex(count: 150),
            zones: [DamageZone(start: 3.5, end: 4.1, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1").shortfallAllowance == 0)
        #expect(BoundaryReencodeEngine.repairedSegmentExpectation(
            range: 75..<100, index: cleanIndex(count: 100),
            zones: [DamageZone(start: 3.2, end: 3.5, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1").shortfallAllowance == 0)
    }

    @Test func trimmedSlotBudgetCapsAtATruncatedEnding() {
        let index = cleanIndex(count: 100)
        let budget = BoundaryReencodeEngine.trimmedSlotBudget(
            range: 75..<100, index: index,
            zones: [DamageZone(start: 3.7, end: 4.05, affectsVideo: true)],
            fps: 25, containerStart: 0)
        #expect(budget == 18)
    }

    @Test func trimmedSlotBudgetIsFullForAnInteriorSpan() {
        let index = cleanIndex(count: 200)
        #expect(BoundaryReencodeEngine.trimmedSlotBudget(
            range: 100..<150, index: index,
            zones: [DamageZone(start: 4.5, end: 5.0, affectsVideo: true)],
            fps: 25, containerStart: 0) == 50)
        #expect(BoundaryReencodeEngine.trimmedSlotBudget(
            range: 75..<100, index: cleanIndex(count: 100),
            zones: [DamageZone(start: 3.2, end: 3.5, affectsVideo: true)],
            fps: 25, containerStart: 0) == 25)
    }

    @Test func repairedSegmentArgumentsTrimFramesVAtEof() {
        let args = BoundaryReencodeEngine.repairedSegmentArguments(
            source: src, range: 75..<100, index: cleanIndex(count: 100),
            zones: [DamageZone(start: 3.7, end: 4.05, affectsVideo: true)],
            containerStart: 0, frameRate: "25/1",
            encoder: ["-c:v", "libx264"], output: out)
        let fv = args.firstIndex(of: "-frames:v").map { args[$0 + 1] }
        #expect(fv == "18")
    }

    private var boundedCopyIndex: FrameIndex {
        let pts = (0..<10).map { 1.0 + Double($0) * 0.04 }
        return FrameIndex(pts: pts, keyframeFlags: Array(repeating: true, count: 10))
    }

    @Test func boundedCopySeeksToTheSpanAndSplitsAfterItsFrameCount() {
        let args = BoundaryReencodeEngine.boundedCopyArguments(
            source: src, range: 2..<6, index: boundedCopyIndex, containerStart: 1.0,
            segmentPattern: "/tmp/cp_%03d.ts")
        #expect(args[args.firstIndex(of: "-ss")! + 1] == "0.08")
        #expect(args.firstIndex(of: "-ss")! < args.firstIndex(of: "-i")!)
        #expect(args[args.firstIndex(of: "-segment_frames")! + 1] == "4")
        #expect(args.contains("-reset_timestamps"))
        #expect(args[args.firstIndex(of: "-t")! + 1] == "2.16")
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
        let args = BoundaryReencodeEngine.boundedCopyArguments(
            source: src, range: 6..<10, index: boundedCopyIndex, containerStart: 1.0,
            segmentPattern: "/tmp/cp_%03d.ts")
        #expect(args[args.firstIndex(of: "-segment_frames")! + 1] == "4")
    }

    @Test func boundedCopyOfAnMpegPsSourceIntoMkvCarriesTheRefill() {
        let bsf = ExportEngine.copyPieceBitstreamFilter(codec: "mpeg2video", ext: "mkv")
        let inputFlags = ExportEngine.ptsRefillInputFlags(codec: "mpeg2video", ext: "mkv")
        let args = BoundaryReencodeEngine.boundedCopyArguments(
            source: src, range: 2..<6, index: boundedCopyIndex, containerStart: 1.0,
            segmentPattern: "/tmp/cp_%03d.mkv", bitstreamFilter: bsf, inputFlags: inputFlags)
        #expect(args[args.firstIndex(of: "-fflags")! + 1] == "+genpts")
        #expect(args.firstIndex(of: "-fflags")! < args.firstIndex(of: "-i")!)
        let cIndex = args.firstIndex(of: "-c")!
        #expect(args[cIndex + 1] == "copy")
        #expect(args[cIndex + 2] == "-bsf:v")
        #expect(args[cIndex + 3] == ExportEngine.ptsRefillFilter)
        #expect(args.firstIndex(of: "-bsf:v")! < args.firstIndex(of: "-f")!)
    }

    @Test func boundedCopyOutsideTheRefillScopeCarriesNeither() {
        let tsArgs = BoundaryReencodeEngine.boundedCopyArguments(
            source: src, range: 2..<6, index: boundedCopyIndex, containerStart: 1.0,
            segmentPattern: "/tmp/cp_%03d.ts",
            bitstreamFilter: ExportEngine.copyPieceBitstreamFilter(codec: "mpeg2video", ext: "ts"),
            inputFlags: ExportEngine.ptsRefillInputFlags(codec: "mpeg2video", ext: "ts"))
        #expect(!tsArgs.contains("-fflags"))
        #expect(!tsArgs.contains("-bsf:v"))

        let h264Args = BoundaryReencodeEngine.boundedCopyArguments(
            source: src, range: 2..<6, index: boundedCopyIndex, containerStart: 1.0,
            segmentPattern: "/tmp/cp_%03d.mkv",
            bitstreamFilter: ExportEngine.copyPieceBitstreamFilter(codec: "h264", ext: "mkv"),
            inputFlags: ExportEngine.ptsRefillInputFlags(codec: "h264", ext: "mkv"))
        #expect(!h264Args.contains("-fflags"))
    }

    @Test func aBoundedCutExpectsOnlyTheReadItWillActuallyDo() {
        let plan = SegmentPlan(inFrame: 100, outFrame: 1999, inSegmentTime: 4.0, outSegmentTime: 80.0)
        #expect(BoundaryReencodeEngine.segmentMuxExpectedSeconds(plan: plan, sourceSpan: 16_560.0) == 82.0)
    }

    @Test func anUnboundedCutStillExpectsTheWholeSourceSpan() {
        let plan = SegmentPlan(inFrame: 100, outFrame: 1999, inSegmentTime: 4.0, outSegmentTime: nil)
        #expect(BoundaryReencodeEngine.segmentMuxExpectedSeconds(plan: plan, sourceSpan: 16_560.0) == 16_560.0)
        #expect(BoundaryReencodeEngine.segmentMuxExpectedSeconds(plan: plan, sourceSpan: nil) == nil)
    }

    @Test func theReadMarginNeverPushesTheExpectationPastTheSource() {
        let plan = SegmentPlan(inFrame: 0, outFrame: 10, inSegmentTime: nil, outSegmentTime: 11.5)
        #expect(BoundaryReencodeEngine.segmentMuxExpectedSeconds(plan: plan, sourceSpan: 12.0) == 12.0)
    }

    @Test func aSeekedCutExpectsOnlyTheSpanBetweenTheLandingAndTheBound() {
        let plan = SegmentPlan(inFrame: 400_000, outFrame: 400_250,
                               inSegmentTime: 8000.07, outSegmentTime: 8005.03)
        let seek = ExportEngine.CopyHeadSeek(seek: 7990.14, origin: 7985.14)
        let expected = BoundaryReencodeEngine.segmentMuxExpectedSeconds(
            plan: plan, sourceSpan: 16_560.0, headSeek: seek)
        #expect(expected != nil && abs(expected! - 21.89) < 0.001)
        let toEof = SegmentPlan(inFrame: 400_000, outFrame: 830_000,
                                inSegmentTime: 8000.07, outSegmentTime: nil)
        let eofExpected = BoundaryReencodeEngine.segmentMuxExpectedSeconds(
            plan: toEof, sourceSpan: 16_560.0, headSeek: seek)
        #expect(eofExpected != nil && abs(eofExpected! - 8574.86) < 0.001)
    }

    @Test func theLandingProbeSeeksAndCopiesExactlyOnePacket() {
        let args = BoundaryReencodeEngine.landingProbeArguments(
            source: src, seek: 7990.14, output: URL(fileURLWithPath: "/tmp/probe.nut"))
        let ss = args.firstIndex(of: "-ss")
        #expect(ss != nil && ss! < args.firstIndex(of: "-i")!)
        #expect(args[args.index(after: ss!)] == "7990.14")
        #expect(args.contains("-copyts"))
        #expect(args[args.index(after: args.firstIndex(of: "-frames:v")!)] == "1")
        #expect(args.contains("-c") && args.contains("copy"))
        #expect(args[args.index(after: args.firstIndex(of: "-f")!)] == "nut")
        #expect(args.last == "/tmp/probe.nut")
    }

    @Test func discardingDeadSegmentsKeepsOnlyTheWantedPiece() throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-dead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let names = ["c0_s1_cp_000.mkv", "c0_s1_cp_001.mkv", "c0_s1_cp_002.mkv",
                     "c0_s3_cp_000.mkv", "c0_s2_re.mkv", "c0_s4_cp.mkv", "c1_s1_cp_000.mkv"]
        for n in names {
            try Data().write(to: work.appendingPathComponent(n))
        }
        BoundaryReencodeEngine.discardDeadSegments(
            prefix: "c0_s1_cp_", keeping: work.appendingPathComponent("c0_s1_cp_001.mkv"), in: work)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: work.path))
        #expect(left == ["c0_s1_cp_001.mkv", "c0_s3_cp_000.mkv", "c0_s2_re.mkv",
                         "c0_s4_cp.mkv", "c1_s1_cp_000.mkv"])
    }

    @Test func mbaffRepairArgsCarryTheInterlaceFlagsCrf18AndScanFromFieldOrder() {
        let tff = BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: "tt")
        #expect(tff.contains("libx264"))
        #expect(tff[tff.firstIndex(of: "-flags")! + 1] == "+ildct+ilme")
        #expect(tff[tff.firstIndex(of: "-vf")! + 1] == "setparams=field_mode=tff")
        #expect(tff[tff.firstIndex(of: "-crf")! + 1] == "18")
        #expect(tff[tff.firstIndex(of: "-forced-idr")! + 1] == "1")
        let params = tff[tff.firstIndex(of: "-x264-params")! + 1]
        #expect(params.contains("ref=5") && params.contains("open_gop=0") && params.contains("b-pyramid=0"))
        #expect(!tff.contains("-bsf:v"))

        let bff = BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: "bb")
        #expect(bff[bff.firstIndex(of: "-vf")! + 1] == "setparams=field_mode=bff")
        let unknown = BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: nil)
        #expect(unknown[unknown.firstIndex(of: "-vf")! + 1] == "setparams=field_mode=tff")
    }
}
