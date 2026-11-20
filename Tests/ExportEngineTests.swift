import Testing
import Foundation
@testable import ClipStitcher

struct ExportEngineTests {
    private let src = URL(fileURLWithPath: "/tmp/clip.mp4")

    @Test func wantedSegmentIsZeroWithoutAHeadCut() {
        let plan = SegmentPlan(inFrame: 0, outFrame: 8,
                               inSegmentTime: nil, outSegmentTime: 0.30)
        #expect(ExportEngine.wantedSegmentIndex(plan: plan) == 0)
    }

    @Test func wantedSegmentIsOneAfterAHeadCut() {
        let plan = SegmentPlan(inFrame: 2, outFrame: 8,
                               inSegmentTime: 0.06, outSegmentTime: 0.30)
        #expect(ExportEngine.wantedSegmentIndex(plan: plan) == 1)
    }

    @Test func cutArgumentsJoinBothCutTimesAndCopyVideoOnly() {
        let plan = SegmentPlan(inFrame: 2, outFrame: 8,
                               inSegmentTime: 0.06, outSegmentTime: 0.30)
        let args = ExportEngine.cutArguments(source: src, plan: plan, segmentPattern: "/tmp/seg_%03d.mp4")
        #expect(args.contains("-c") && args.contains("copy"))
        let times = args[args.firstIndex(of: "-segment_times")! + 1]
        #expect(times == "0.06,0.3")
        #expect(args.contains("0:v:0"))
        #expect(!args.contains("0:a:0?"))
        #expect(args.last == "/tmp/seg_%03d.mp4")
    }

    @Test func aClipTrimmingNeitherEndNeedsNoCut() {
        let whole = SegmentPlan(inFrame: 0, outFrame: 9,
                                inSegmentTime: nil, outSegmentTime: nil)
        #expect(ExportEngine.needsCut(whole) == false)
        let trimmed = SegmentPlan(inFrame: 2, outFrame: 9,
                                  inSegmentTime: 0.06, outSegmentTime: nil)
        #expect(ExportEngine.needsCut(trimmed) == true)
    }

    @Test func remuxArgumentsCopyTheWholeClipVideoToOneFile() {
        let out = URL(fileURLWithPath: "/tmp/clip0.mp4")
        let args = ExportEngine.remuxArguments(source: src, output: out)
        #expect(!args.contains("-f"))
        #expect(args.contains("-c") && args.contains("copy"))
        #expect(args.contains("0:v:0"))
        #expect(args.last == "/tmp/clip0.mp4")
    }

    @Test func concatArgumentsUseTheConcatDemuxerWithCopy() {
        let args = ExportEngine.concatArguments(listFile: URL(fileURLWithPath: "/tmp/list.txt"),
                                                output: URL(fileURLWithPath: "/tmp/out.mp4"))
        #expect(args.contains("concat"))
        #expect(args.contains("-safe") && args.contains("0"))
        #expect(args.contains("-c") && args.contains("copy"))
        #expect(args.last == "/tmp/out.mp4")
    }

    @Test func concatListEscapesSingleQuotesInPaths() {
        let pieces = [URL(fileURLWithPath: "/tmp/a's clip.mp4"), URL(fileURLWithPath: "/tmp/b.mp4")]
        let list = ExportEngine.concatListContents(pieces: pieces)
        #expect(list.contains("file '/tmp/a'\\''s clip.mp4'"))
        #expect(list.contains("file '/tmp/b.mp4'"))
    }

    @Test func mpeg2IntoMkvGetsThePtsRefillFilter() {
        let bsf = ExportEngine.ptsRefillBitstreamFilter(codec: "mpeg2video", ext: "mkv")
        #expect(bsf == ["-bsf:v", "setts=pts=if(eq(PTS\\,NOPTS)\\,DTS\\,PTS)"])
    }

    @Test func damagedSourcesIntoMkvGetThePtsRefillWhateverTheCodec() {
        let want = ["-bsf:v", "setts=pts=if(eq(PTS\\,NOPTS)\\,DTS\\,PTS)"]
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "h264", ext: "mkv", damaged: true) == want)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "hevc", ext: "mkv", damaged: true) == want)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "h264", ext: "mp4", damaged: true).isEmpty)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "h264", ext: "ts", damaged: true).isEmpty)
    }

    @Test func mpeg2IntoMkvAlsoGetsTheDemuxerPtsRefill() {
        #expect(ExportEngine.ptsRefillInputFlags(codec: "mpeg2video", ext: "mkv")
            == ["-fflags", "+genpts"])
        #expect(ExportEngine.ptsRefillInputFlags(codec: "h264", ext: "mkv", damaged: true)
            == ["-fflags", "+genpts"])
        #expect(ExportEngine.ptsRefillInputFlags(codec: "hevc", ext: "mkv", damaged: true)
            == ["-fflags", "+genpts"])
        for codec in ["hevc", "h264", "mpeg2video", nil] {
            for ext in ["mkv", "mp4", "ts"] {
                for damaged in [false, true] {
                    let flags = ExportEngine.ptsRefillInputFlags(
                        codec: codec, ext: ext, damaged: damaged)
                    let bsf = ExportEngine.ptsRefillBitstreamFilter(
                        codec: codec, ext: ext, damaged: damaged)
                    #expect(flags.isEmpty == bsf.isEmpty)
                }
            }
        }
    }

    @Test func theDemuxerPtsRefillReachesTheCommandBeforeTheInput() {
        let flags = ExportEngine.ptsRefillInputFlags(codec: "mpeg2video", ext: "mkv")
        let plan = SegmentPlan(inFrame: 10, outFrame: 20, inSegmentTime: 1.0, outSegmentTime: 2.0)
        let cut = ExportEngine.cutArguments(
            source: src, plan: plan, segmentPattern: "/tmp/p_%03d.mkv",
            headSeek: ExportEngine.CopyHeadSeek(seek: 5.0, origin: 4.8), inputFlags: flags)
        #expect(cut.firstIndex(of: "-fflags")! < cut.firstIndex(of: "-i")!)
        #expect(cut[cut.firstIndex(of: "-fflags")! + 1] == "+genpts")
        #expect(cut.firstIndex(of: "-ss")! < cut.firstIndex(of: "-i")!)

        let remux = ExportEngine.remuxArguments(
            source: src, output: URL(fileURLWithPath: "/tmp/o.mkv"), inputFlags: flags)
        #expect(remux.firstIndex(of: "-fflags")! < remux.firstIndex(of: "-i")!)

        #expect(ExportEngine.cutArguments(source: src, plan: plan, segmentPattern: "/tmp/p_%03d.ts")
            == ExportEngine.cutArguments(source: src, plan: plan,
                                         segmentPattern: "/tmp/p_%03d.ts", inputFlags: []))
    }

    @Test func everyOtherCodecContainerComboKeepsItsValidatedCommandShape() {
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "mpeg2video", ext: "ts").isEmpty)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "mpeg2video", ext: "mp4").isEmpty)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "h264", ext: "mkv").isEmpty)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "hevc", ext: "mkv").isEmpty)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: nil, ext: "mkv").isEmpty)
        let plan = SegmentPlan(inFrame: 10, outFrame: 20, inSegmentTime: 1.0, outSegmentTime: 2.0)
        let cut = ExportEngine.cutArguments(source: src, plan: plan, segmentPattern: "/tmp/p_%03d.ts")
        #expect(!cut.contains("-bsf:v"))
        let remux = ExportEngine.remuxArguments(source: src, output: URL(fileURLWithPath: "/tmp/o.ts"))
        #expect(!remux.contains("-bsf:v"))
    }

    @Test func copiedH264AndHevcPiecesRepeatTheirParameterSetsInBand() {
        #expect(ExportEngine.copyPieceBitstreamFilter(codec: "hevc", ext: "mkv")
            == ["-bsf:v", "hevc_mp4toannexb"])
        #expect(ExportEngine.copyPieceBitstreamFilter(codec: "h264", ext: "mp4")
            == ["-bsf:v", "h264_mp4toannexb"])
        #expect(ExportEngine.copyPieceBitstreamFilter(codec: "mpeg2video", ext: "ts").isEmpty)
        #expect(ExportEngine.copyPieceBitstreamFilter(codec: nil, ext: "ts").isEmpty)
    }

    @Test func aSourceWithInBandParameterSetsCopiesWithoutTheRepeat() {
        #expect(ExportEngine.copyPieceBitstreamFilter(
            codec: "hevc", ext: "mkv", inBandParameterSets: true).isEmpty)
        #expect(ExportEngine.copyPieceBitstreamFilter(
            codec: "h264", ext: "mp4", inBandParameterSets: true).isEmpty)
        #expect(ExportEngine.copyPieceBitstreamFilter(
            codec: "mpeg2video", ext: "mkv", inBandParameterSets: true)
            == ["-bsf:v", ExportEngine.ptsRefillFilter])
    }

    @Test func theInBandProbeCountsOnlyAnSpsInsideThePacket() {
        let src = URL(fileURLWithPath: "/m/a.mkv")
        let args = ExportEngine.inBandParameterSetProbeArguments(source: src, seek: 12.5, codec: "hevc")
        #expect(args?.contains("trace_headers") == true)
        #expect(args.map { Array($0.suffix(5)) } == ["-frames:v", "1", "-f", "null", "-"])
        #expect(ExportEngine.inBandParameterSetProbeArguments(
            source: src, seek: 0, codec: "mpeg2video") == nil)

        let header = "Extradata\nVideo Parameter Set\nSequence Parameter Set\nPicture Parameter Set\n"
        #expect(!ExportEngine.tracesInBandParameterSets(
            header + "Packet: 900 bytes, key frame\nSlice Segment Header\n"))
        #expect(ExportEngine.tracesInBandParameterSets(
            header + "Packet: 900 bytes, key frame\nVideo Parameter Set\nSequence Parameter Set\n"
                + "Picture Parameter Set\n"))
        #expect(!ExportEngine.tracesInBandParameterSets(
            header + "Packet: 900 bytes, key frame\nSequence Parameter Set\nSlice Header\n"))
        #expect(!ExportEngine.tracesInBandParameterSets(header))
    }

    @Test func aCopyPieceNeverEmitsMoreThanOneBitstreamFilterArgument() {
        for codec in ["hevc", "h264", "mpeg2video", nil] {
            for ext in ["mkv", "mp4", "ts"] {
                for damaged in [false, true] {
                    let args = ExportEngine.copyPieceBitstreamFilter(
                        codec: codec, ext: ext, damaged: damaged)
                    #expect(args.count == (args.isEmpty ? 0 : 2))
                    #expect(args.filter { $0 == "-bsf:v" }.count == (args.isEmpty ? 0 : 1))
                }
            }
        }
        #expect(ExportEngine.copyPieceBitstreamFilter(codec: "mpeg2video", ext: "mkv")
            == ["-bsf:v", ExportEngine.ptsRefillFilter])
    }

    @Test func aDamagedSourcesCopyKeepsTheRefillWithoutTheAnnexbConversion() {
        let args = ExportEngine.copyPieceBitstreamFilter(codec: "hevc", ext: "mkv", damaged: true)
        #expect(args == ["-bsf:v", ExportEngine.ptsRefillFilter])
        #expect(!args.contains { $0.contains("mp4toannexb") })
        #expect(ExportEngine.copyPieceBitstreamFilter(codec: "hevc", ext: "ts", damaged: true).isEmpty)
    }

    @Test func everyReencodedPieceRepeatsItsParameterSetsInBand() {
        let index = FrameIndex(pts: (0..<8).map { 0.24 + Double($0) * 0.04 },
                               keyframeFlags: [true, false, false, false, true, false, false, false])
        let boundary = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 6..<8, index: index,
            encoder: ["-c:v", "libx264"], output: URL(fileURLWithPath: "/tmp/seg.mkv"))
        #expect(boundary[boundary.firstIndex(of: "-bsf:v")! + 1] == ExportEngine.parameterSetRepeatFilter)
        let repaired = BoundaryReencodeEngine.repairedSegmentArguments(
            source: src, range: 0..<8, index: index,
            zones: [DamageZone(start: 0.5, end: 0.6, affectsVideo: true)],
            containerStart: 0.24, frameRate: "25/1",
            encoder: ["-c:v", "libx264"], output: URL(fileURLWithPath: "/tmp/rep.mkv"))
        #expect(repaired[repaired.firstIndex(of: "-bsf:v")! + 1] == ExportEngine.parameterSetRepeatFilter)
        #expect(boundary.filter { $0 == "-bsf:v" }.count == 1)
        #expect(repaired.filter { $0 == "-bsf:v" }.count == 1)
    }

    @Test func theCutStopsReadingJustPastTheOutCut() {
        let plan = SegmentPlan(inFrame: 100, outFrame: 1999, inSegmentTime: 4.0, outSegmentTime: 80.0)
        let args = ExportEngine.cutArguments(source: src, plan: plan, segmentPattern: "/tmp/p_%03d.mkv")
        #expect(!args.contains("-to"))
        let i = args.firstIndex(of: "-t")
        #expect(i != nil)
        #expect(Double(args[args.index(after: i!)]) == 82.0)
        #expect(i! > args.firstIndex(of: "-segment_times")!)
        #expect(args.last == "/tmp/p_%03d.mkv")
    }

    @Test func theReadBoundClearsTheOutCutByMoreThanAFrame() {
        let slowestFrameInterval = 1.0 / 23.976
        for out in [0.5, 12.0, 80.0, 16_560.0] {
            let plan = SegmentPlan(inFrame: 0, outFrame: 10, inSegmentTime: nil, outSegmentTime: out)
            let args = ExportEngine.cutArguments(source: src, plan: plan, segmentPattern: "/tmp/p_%03d.ts")
            let bound = Double(args[args.index(after: args.firstIndex(of: "-t")!)])
            #expect(bound != nil && bound! - out > slowestFrameInterval)
        }
    }

    @Test func aCutWithNoOutCutReadsToEof() {
        let plan = SegmentPlan(inFrame: 100, outFrame: 1999, inSegmentTime: 4.0, outSegmentTime: nil)
        let args = ExportEngine.cutArguments(source: src, plan: plan, segmentPattern: "/tmp/p_%03d.ts")
        #expect(!args.contains("-t"))
    }

    private func keyframedIndex(frames: Int = 600, gop: Int = 50, start: Double = 0) -> FrameIndex {
        let pts = (0..<frames).map { start + Double($0) / 50.0 }
        return FrameIndex(pts: pts, keyframeFlags: (0..<frames).map { $0 % gop == 0 })
    }

    @Test func theHeadSeekAnchorsTwoKeyframesBeforeTheInCut() {
        let index = keyframedIndex()
        let plan = SegmentPlan(inFrame: 300, outFrame: 400, inSegmentTime: 5.99, outSegmentTime: 7.99)
        let seek = ExportEngine.copyHeadSeekTarget(plan: plan, index: index, containerStart: 0)
        #expect(seek == 4.0)
    }

    @Test func theHeadSeekFallsBackToTheOnlyEarlierKeyframe() {
        let index = keyframedIndex(start: 1.44)
        let plan = SegmentPlan(inFrame: 50, outFrame: 90, inSegmentTime: 0.99, outSegmentTime: 1.79)
        #expect(ExportEngine.copyHeadSeekTarget(plan: plan, index: index, containerStart: 1.44) == 0)
        let later = SegmentPlan(inFrame: 150, outFrame: 190, inSegmentTime: 2.99, outSegmentTime: 3.79)
        #expect(ExportEngine.copyHeadSeekTarget(plan: later, index: index, containerStart: 1.44) == 1.0)
    }

    @Test func aCopyWithNoHeadGetsNoSeek() {
        let index = keyframedIndex()
        let noInCut = SegmentPlan(inFrame: 0, outFrame: 100, inSegmentTime: nil, outSegmentTime: 2.0)
        #expect(ExportEngine.copyHeadSeekTarget(plan: noInCut, index: index, containerStart: 0) == nil)
        let atFrameZero = SegmentPlan(inFrame: 0, outFrame: 100, inSegmentTime: 0.0, outSegmentTime: 2.0)
        #expect(ExportEngine.copyHeadSeekTarget(plan: atFrameZero, index: index, containerStart: 0) == nil)
    }

    @Test func theHeadSeekRebasesEveryTimeOntoTheLanding() {
        let plan = SegmentPlan(inFrame: 400_000, outFrame: 400_250,
                               inSegmentTime: 8000.07, outSegmentTime: 8005.03)
        let seek = ExportEngine.CopyHeadSeek(seek: 7990.14, origin: 7985.14)
        let args = ExportEngine.cutArguments(source: src, plan: plan,
                                             segmentPattern: "/tmp/p_%03d.mkv", headSeek: seek)
        let ss = args.firstIndex(of: "-ss")
        #expect(ss != nil && ss! < args.firstIndex(of: "-i")!)
        #expect(args[args.index(after: ss!)] == "7990.14")
        #expect(!args.contains("-copyts"))
        let times = args[args.index(after: args.firstIndex(of: "-segment_times")!)]
        #expect(times == "14.93,19.89")
        let bound = Double(args[args.index(after: args.firstIndex(of: "-t")!)])
        #expect(bound != nil && abs(bound! - 21.89) < 0.001)
    }

    @Test func withoutAHeadSeekTheCutIsUnchanged() {
        let plan = SegmentPlan(inFrame: 100, outFrame: 1999, inSegmentTime: 4.0, outSegmentTime: 80.0)
        let args = ExportEngine.cutArguments(source: src, plan: plan, segmentPattern: "/tmp/p_%03d.mkv")
        #expect(!args.contains("-ss"))
        #expect(args[args.index(after: args.firstIndex(of: "-segment_times")!)] == "4,80")
        #expect(Double(args[args.index(after: args.firstIndex(of: "-t")!)]) == 82.0)
    }

    @Test func aSeekedCutWithNoOutCutStillReadsToEof() {
        let plan = SegmentPlan(inFrame: 100, outFrame: 1999, inSegmentTime: 4.0, outSegmentTime: nil)
        let seek = ExportEngine.CopyHeadSeek(seek: 1.0, origin: 1.0)
        let args = ExportEngine.cutArguments(source: src, plan: plan,
                                             segmentPattern: "/tmp/p_%03d.ts", headSeek: seek)
        #expect(!args.contains("-t"))
        #expect(args[args.index(after: args.firstIndex(of: "-segment_times")!)] == "3")
    }

    @Test func exportWideTimescaleIsTheLcmOfTheProbes() {
        #expect(ExportEngine.exportWideTimescale(probed: [25000, 90000]) == 450000)
        #expect(ExportEngine.exportWideTimescale(probed: [16000, 25000]) == 400000)
        #expect(ExportEngine.exportWideTimescale(probed: [16000]) == 16000)
        #expect(ExportEngine.exportWideTimescale(probed: [25000, 25000]) == 25000)
    }

    @Test func exportWideTimescaleRefusesToOverflowTheMuxerRange() {
        #expect(ExportEngine.exportWideTimescale(probed: [1_000_003, 999_999_937]) == nil)
        #expect(ExportEngine.exportWideTimescale(probed: []) == nil)
    }

    @Test func exportWideTimescaleFromProbesIsAllOrNothing() {
        #expect(ExportEngine.exportWideTimescale(probes: [25000, 90000]) == 450000)
        #expect(ExportEngine.exportWideTimescale(probes: [25000, nil, 90000]) == nil)
        #expect(ExportEngine.exportWideTimescale(probes: [nil]) == nil)
        #expect(ExportEngine.exportWideTimescale(probes: []) == nil)
        #expect(ExportEngine.exportWideTimescale(probes: [25000]) == 25000)
    }

    @Test func copyCommandsCarryTheExportWideTimescale() {
        let plan = SegmentPlan(inFrame: 0, outFrame: 10, inSegmentTime: nil, outSegmentTime: 2.0)
        let cut = ExportEngine.cutArguments(source: src, plan: plan,
                                            segmentPattern: "/tmp/p_%03d.mp4", trackTimescale: 450000)
        let i = cut.firstIndex(of: "-segment_format_options")
        #expect(i != nil && cut[cut.index(after: i!)] == "video_track_timescale=450000")
        let remux = ExportEngine.remuxArguments(source: src, output: URL(fileURLWithPath: "/tmp/o.mp4"),
                                                trackTimescale: 450000)
        let j = remux.firstIndex(of: "-video_track_timescale")
        #expect(j != nil && remux[remux.index(after: j!)] == "450000")
        #expect(!ExportEngine.cutArguments(source: src, plan: plan, segmentPattern: "/tmp/p_%03d.ts")
            .contains("-segment_format_options"))
        #expect(!ExportEngine.remuxArguments(source: src, output: URL(fileURLWithPath: "/tmp/o.ts"))
            .contains("-video_track_timescale"))
    }

    @Test func theBitstreamFilterLandsBeforeTheSegmentMuxerFlags() {
        let plan = SegmentPlan(inFrame: 0, outFrame: 10, inSegmentTime: nil, outSegmentTime: 2.0)
        let bsf = ExportEngine.ptsRefillBitstreamFilter(codec: "mpeg2video", ext: "mkv")
        let args = ExportEngine.cutArguments(source: src, plan: plan,
                                             segmentPattern: "/tmp/p_%03d.mkv", bitstreamFilter: bsf)
        let bsfIndex = args.firstIndex(of: "-bsf:v")
        let segIndex = args.firstIndex(of: "segment")
        #expect(bsfIndex != nil && segIndex != nil && bsfIndex! < segIndex!)
        let remux = ExportEngine.remuxArguments(source: src, output: URL(fileURLWithPath: "/tmp/o.mkv"),
                                                bitstreamFilter: bsf)
        #expect(remux.contains("-bsf:v") && remux.last == "/tmp/o.mkv")
    }

    @Test func audioInputArgsSeekAndLimitToTheClipRange() {
        let a = ExportEngine.audioInputArgs(source: src, start: 1654.8, end: 1727.6)
        #expect(a == ["-max_error_rate", "1.0", "-ss", "1654.8", "-t", "72.8", "-i", "/tmp/clip.mp4"])
    }

    @Test func audioInputArgsOmitSeekForAnOpenStart() {
        let a = ExportEngine.audioInputArgs(source: src, start: nil, end: 30.0)
        #expect(a == ["-max_error_rate", "1.0", "-t", "30", "-i", "/tmp/clip.mp4"])
    }

    @Test func audioInputArgsOmitDurationForAnOpenEnd() {
        let a = ExportEngine.audioInputArgs(source: src, start: 10.0, end: nil)
        #expect(a == ["-max_error_rate", "1.0", "-ss", "10", "-i", "/tmp/clip.mp4"])
    }

    @Test func keptWindowSubtractsTheContainerStartFromTheSeek() {
        let w = ExportEngine.keptWindow(inPts: 60.2, outPts: 70.2, outEndPts: 70.24, firstPts: 0.24,
                                        lastPts: 4020.2, frameDuration: 0.04, containerStart: 0.24)
        #expect(w.start == 59.96)
        #expect(abs(w.end! - 70.0) < 1e-9)
        #expect(abs(w.duration - 10.04) < 1e-9)
    }

    @Test func keptWindowClampsANegativeSeekToZero() {
        let w = ExportEngine.keptWindow(inPts: 0.10, outPts: 5.0, outEndPts: 5.04, firstPts: 0.10,
                                        lastPts: 100.0, frameDuration: 0.04, containerStart: 0.24)
        #expect(w.start == 0)
        #expect(abs(w.end! - 4.8) < 1e-9)
        #expect(w.duration > 0)
    }

    @Test func keptWindowIsUnchangedOnAZeroStartContainer() {
        let w = ExportEngine.keptWindow(inPts: 57.0, outPts: 60.0, outEndPts: 60.04, firstPts: 0.04,
                                        lastPts: 5169.0, frameDuration: 0.04, containerStart: 0)
        #expect(w.start == 57.0)
        #expect(abs(w.end! - 60.04) < 1e-9)
        #expect(abs(w.duration - 3.04) < 1e-9)
    }

    @Test func keptWindowClosedOutAtFileEndUsesTheFrameDuration() {
        let w = ExportEngine.keptWindow(inPts: 4010.2, outPts: 4020.2, outEndPts: nil, firstPts: 0.24,
                                        lastPts: 4020.2, frameDuration: 0.04, containerStart: 0.24)
        #expect(w.start == 4009.96)
        #expect(abs(w.end! - 4020.0) < 1e-9)
        #expect(abs(w.duration - 10.04) < 1e-9)
    }

    @Test func keptWindowOpenStartReadsFromTheFileStart() {
        let w = ExportEngine.keptWindow(inPts: nil, outPts: 10.24, outEndPts: 10.28, firstPts: 0.24,
                                        lastPts: 4020.2, frameDuration: 0.04, containerStart: 0.24)
        #expect(w.start == nil)
        #expect(abs(w.end! - 10.04) < 1e-9)
        #expect(abs(w.duration - 10.04) < 1e-9)
    }

    @Test func keptWindowOpenEndRunsToTheLastFrame() {
        let w = ExportEngine.keptWindow(inPts: 4010.2, outPts: nil, outEndPts: nil, firstPts: 0.24,
                                        lastPts: 4020.2, frameDuration: 0.04, containerStart: 0.24)
        #expect(w.start == 4009.96)
        #expect(w.end == nil)
        #expect(abs(w.duration - 10.04) < 1e-9)
    }

    @Test func keptWindowDurationEqualsClipSpanForATrimmedClip() {
        let pts = [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52]
        let index = FrameIndex(pts: pts,
                               keyframeFlags: [true, false, false, false, true, false, false, false])
        let item = ExportItem(source: URL(fileURLWithPath: "/tmp/a.mpg"),
                              segments: [PlannedSegment(kind: .copy, range: 0..<4)], index: index)
        let w = ExportEngine.keptWindow(inPts: pts[0], outPts: pts[3], outEndPts: pts[4],
                                        firstPts: pts.first, lastPts: pts.last,
                                        frameDuration: 0.04, containerStart: 0.24)
        #expect(abs(w.duration - (ExportEngine.clipSpan(item) ?? -1)) < 1e-9)
        #expect(abs(w.duration - 0.16) < 1e-9)
    }

    @Test func keptWindowSingleFrameKeepForcesOneFrame() {
        let w = ExportEngine.keptWindow(inPts: 1.0, outPts: 1.0, outEndPts: 1.04,
                                        firstPts: 0.0, lastPts: 5.0, frameDuration: 0.04,
                                        containerStart: 0)
        #expect(abs(w.duration - 0.04) < 1e-9)
        #expect(w.start == 1.0)
        #expect(abs(w.end! - 1.04) < 1e-9)
    }

    private let stereoTrack = AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2)

    @Test func audioMuxConcatenatesItemAudioOverCopiedVideo() {
        let video = URL(fileURLWithPath: "/tmp/joined.ts")
        let items = [
            ExportItem(source: src, codec: "mpeg2video", audioStart: 1.0, audioEnd: 2.0),
            ExportItem(source: src, codec: "mpeg2video", audioStart: 5.0, audioEnd: 7.0),
        ]
        let args = ExportEngine.audioMuxArguments(videoInput: video, items: items, tracks: [stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.ts"))
        #expect(args.contains("0:v:0") && args.contains("-c:v") && args.contains("copy"))
        #expect(args.contains("-c:a") && args.contains("aac"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[1:a:0]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo[c0t0src];"
                    + "anullsrc=r=48000:cl=stereo[c0t0pad];"
                    + "[c0t0src][c0t0pad]concat=n=2:v=0:a=1,atrim=end_sample=48000[c0t0];"
                    + "[2:a:0]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo[c1t0src];"
                    + "anullsrc=r=48000:cl=stereo[c1t0pad];"
                    + "[c1t0src][c1t0pad]concat=n=2:v=0:a=1,atrim=end_sample=96000[c1t0];"
                    + "[c0t0][c1t0]concat=n=2:v=0:a=1[a0]")
        #expect(!fc.contains("apad"))
        #expect(args.contains("[a0]"))
        #expect(args.last == "/tmp/out.ts")
    }

    @Test func audioMuxInsertsTheLegsMixBeforeItsConform() {
        var mixed = ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 1)
        mixed.audioMixFilters = ["pan=stereo|c0=c0|c1=c0"]
        let items = [mixed, ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 1)]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items, tracks: [stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.mkv"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc.contains("[0:a:0]pan=stereo|c0=c0|c1=c0,aresample=48000:async=1:first_pts=0,"
                          + "aformat=channel_layouts=stereo[c0t0src]"))
        #expect(fc.contains("[c0t0src][c0t0pad]concat=n=2:v=0:a=1,atrim=end_sample=48000[c0t0]"))
        #expect(fc.contains("[1:a:0]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo[c1t0src]"))
        #expect(fc.contains("[c1t0src][c1t0pad]concat=n=2:v=0:a=1,atrim=end_sample=48000[c1t0]"))
    }

    @Test func audioMuxBacksEveryRealLegWithSilenceBeforeTheLengthCut() {
        let items = [
            ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 2),
            ExportItem(source: src, codec: "h264", audioStart: 10, audioEnd: 14),
        ]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items, tracks: [stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.mkv"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc.contains("anullsrc=r=48000:cl=stereo[c0t0pad]"))
        #expect(fc.contains("anullsrc=r=48000:cl=stereo[c1t0pad]"))
        #expect(fc.contains("[c0t0src][c0t0pad]concat=n=2:v=0:a=1,atrim=end_sample=96000[c0t0]"))
        #expect(fc.contains("[c1t0src][c1t0pad]concat=n=2:v=0:a=1,atrim=end_sample=192000[c1t0]"))
        #expect(fc.components(separatedBy: "anullsrc").count - 1 == 2)
        #expect(!fc.contains("apad"))
    }

    @Test func audioMuxLeavesALegWithNoKnownLengthUnforced() {
        let items = [ExportItem(source: src, codec: "h264", audioStart: 1.0, audioEnd: nil)]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items, tracks: [stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.mkv"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[0:a:0]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo[c0t0];"
                    + "[c0t0]concat=n=1:v=0:a=1[a0]")
        #expect(!fc.contains("atrim"))
    }

    @Test func audioMuxNeverCutsALegToZeroSamples() {
        let items = [ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 2,
                                audioSources: [.stream(0), nil], audioDuration: 0.000004)]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items,
                                                  tracks: [stereoTrack, stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.mkv"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(!fc.contains("end_sample=0"))
        #expect(fc.contains("atrim=end_sample=1[c0t0]"))
        #expect(fc.contains("anullsrc=r=48000:cl=stereo,atrim=end_sample=1[c0t1]"))
    }

    @Test func audioMuxSilenceFillsAClipWithoutTheTrack(){
        let video = URL(fileURLWithPath: "/tmp/joined.mkv")
        let monoTrack = AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 1)
        let items = [
            ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 2,
                       audioSources: [.stream(0), .stream(1)]),
            ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 2,
                       audioSources: [.stream(0)]),
        ]
        let args = ExportEngine.audioMuxArguments(videoInput: video, items: items, tracks: [stereoTrack, monoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.mkv"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(!fc.contains("[2:a:0]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=mono[c1t1src]"))
        #expect(fc.contains("anullsrc=r=48000:cl=mono,atrim=end_sample=96000[c1t1]"))
        #expect(!fc.contains("anullsrc=r=48000:cl=mono,aresample"))
        #expect(fc.contains("[c0t0][c1t0]concat=n=2:v=0:a=1[a0]"))
        #expect(fc.contains("[c0t1][c1t1]concat=n=2:v=0:a=1[a1]"))
        #expect(args.contains("[a0]") && args.contains("[a1]"))
    }

    @Test func audioMuxReadsAnExternalFileAsItsOwnInput() {
        let external = URL(fileURLWithPath: "/tmp/demo.mkv")
        let items = [ExportItem(source: src, codec: "h264", audioStart: 10.0, audioEnd: 12.0,
                                audioSources: [.stream(0), .external(external, stream: 1)])]
        let args = ExportEngine.audioMuxArguments(videoInput: URL(fileURLWithPath: "/tmp/joined.mp4"),
                                                  items: items, tracks: [stereoTrack, stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.mp4"))
        #expect(args.contains("/tmp/demo.mkv"))
        #expect(args.filter { $0 == "10" }.count == 2 && args.filter { $0 == "2" }.count == 2)
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc.contains("[2:a:1]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo[c0t1src]"))
        #expect(fc.contains("[c0t1src][c0t1pad]concat=n=2:v=0:a=1,atrim=end_sample=96000[c0t1]"))
    }

    @Test func audioMuxSharesOneInputAcrossTwoStreamsOfTheSameExternalFile() {
        let external = URL(fileURLWithPath: "/tmp/demo.mkv")
        let items = [ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 2,
                                audioSources: [.external(external, stream: 0), .external(external, stream: 1)])]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items,
                                                  tracks: [stereoTrack, stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.mka"))
        #expect(args.filter { $0 == "/tmp/demo.mkv" }.count == 1)
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc.contains("[1:a:0]") && fc.contains("[1:a:1]"))
    }

    @Test func audioMuxWritesPerTrackMetadata() {
        let tracks = [
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2, language: "eng", title: "World Feed"),
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2, title: "Natural Sounds"),
        ]
        let items = [ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 2,
                                audioSources: [.stream(0), .stream(1)])]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items, tracks: tracks,
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.mkv"))
        let joined = args.joined(separator: " ")
        #expect(joined.contains("-metadata:s:a:0 language=eng"))
        #expect(joined.contains("-metadata:s:a:0 title=World Feed"))
        #expect(joined.contains("-metadata:s:a:1 title=Natural Sounds"))
        #expect(!joined.contains("-metadata:s:a:1 language"))
    }

    @Test func audioMuxPrefersTheExplicitKeptDuration() {
        let items = [ExportItem(source: src, codec: "h264", audioStart: 1.0, audioEnd: 2.0,
                                audioSources: [.stream(0)], audioDuration: 1.5)]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items, tracks: [stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/a.m4a"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc.contains("concat=n=2:v=0:a=1,atrim=end_sample=72000[c0t0]"))
    }

    @Test func audioMuxWithoutVideoStartsAudioInputsAtZero() {
        let items = [ExportItem(source: src, codec: "mpeg2video", audioStart: 1.0, audioEnd: 2.0)]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items, tracks: [stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/a.m4a"))
        #expect(!args.contains("0:v:0"))
        #expect(!args.contains("-c:v"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc.hasPrefix("[0:a:0]"))
        #expect(fc.hasSuffix("concat=n=1:v=0:a=1[a0]"))
    }

    @Test func audioMuxEncodesToTheGivenCodec() {
        let items = [ExportItem(source: src, codec: "mpeg2video", audioStart: 1.0, audioEnd: 2.0)]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items, tracks: [stereoTrack],
                                                  audioCodec: "mp2", output: URL(fileURLWithPath: "/tmp/a.ts"))
        let ca = args[args.firstIndex(of: "-c:a")! + 1]
        #expect(ca == "mp2")
    }

    @Test func concatListOmitsDurationsByDefault() {
        let pieces = [URL(fileURLWithPath: "/tmp/a.mkv"), URL(fileURLWithPath: "/tmp/b.mkv")]
        let list = ExportEngine.concatListContents(pieces: pieces)
        #expect(!list.contains("duration"))
        #expect(list == "file '/tmp/a.mkv'\nfile '/tmp/b.mkv'\n")
    }

    @Test func concatListEmitsDurationDirectivesAlignedToPieces() {
        let pieces = [URL(fileURLWithPath: "/tmp/cp.mkv"), URL(fileURLWithPath: "/tmp/re.mkv")]
        let list = ExportEngine.concatListContents(pieces: pieces, durations: [3.56, nil])
        #expect(list == "file '/tmp/cp.mkv'\nduration 3.56\nfile '/tmp/re.mkv'\n")
    }

    @Test func concatListSkipsNonPositiveDurations() {
        let pieces = [URL(fileURLWithPath: "/tmp/a.mkv"), URL(fileURLWithPath: "/tmp/b.mkv")]
        let list = ExportEngine.concatListContents(pieces: pieces, durations: [0, nil])
        #expect(!list.contains("duration"))
    }

    @Test func clipSpanOfATrimmedSmartRenderedClipIsExact() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let item = ExportItem(source: URL(fileURLWithPath: "/tmp/a.mpg"),
                              segments: [PlannedSegment(kind: .copy, range: 0..<4)], index: index)
        #expect(abs((ExportEngine.clipSpan(item) ?? -1) - 0.16) < 1e-9)
    }

    @Test func clipSpanOfARunToEndClipAddsOneFrameSlot() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let item = ExportItem(source: URL(fileURLWithPath: "/tmp/a.mpg"),
                              segments: [PlannedSegment(kind: .copy, range: 0..<4),
                                         PlannedSegment(kind: .reEncode, range: 4..<8)], index: index)
        #expect(abs((ExportEngine.clipSpan(item) ?? -1) - 0.32) < 1e-9)
    }

    @Test func clipSpanOfAConformedClipIsTheKeptDuration() {
        let vp = VideoProperties(codec: "h264", profile: nil, level: nil, width: 704, height: 528,
                                 frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: nil,
                                 sampleAspectRatio: nil, colorPrimaries: nil, colorTransfer: nil,
                                 colorRange: nil)
        var item = ExportItem(source: URL(fileURLWithPath: "/tmp/a.mp4"),
                              audioStart: 2.0, audioEnd: 5.0, audioDuration: 12.5,
                              conform: ConformEngine.VideoConform(sourceVideo: vp, targetVideo: vp))
        #expect(ExportEngine.clipSpan(item) == 12.5)
        item.audioDuration = nil
        #expect(ExportEngine.clipSpan(item) == 3.0)
    }

    @Test func clipSpansLastClipAndUncomputableSpansAreNil() {
        let index = FrameIndex(pts: [0.0, 0.04, 0.08, 0.12],
                               keyframeFlags: [true, false, false, false])
        let trimmed = ExportItem(source: URL(fileURLWithPath: "/tmp/a.mp4"),
                                 segments: [PlannedSegment(kind: .copy, range: 0..<2)], index: index)
        let planless = ExportItem(source: URL(fileURLWithPath: "/tmp/b.mp4"))
        let spans = ExportEngine.clipSpans(items: [trimmed, planless, trimmed])
        #expect(spans.count == 3)
        #expect(abs((spans[0] ?? -1) - 0.08) < 1e-9)
        #expect(spans[1] == nil)
        #expect(spans[2] == nil)
    }

    @Test func timestampDefectPassesUniformSpacing() {
        let pts = (0..<100).map { 0.04 * Double($0) }
        #expect(ExportEngine.timestampDefect(pts: pts) == nil)
    }

    @Test func timestampDefectCatchesASeamGap() {
        var pts = (0..<89).map { 0.04 * Double($0) }
        pts += (89..<100).map { 0.04 * Double($0) + 0.04 }
        let reason = ExportEngine.timestampDefect(pts: pts)
        #expect(reason != nil)
        #expect(reason?.contains("gap") == true)
    }

    @Test func timestampDefectCatchesADuplicate() {
        var pts = (0..<50).map { 0.04 * Double($0) }
        pts[25] = pts[24]
        let reason = ExportEngine.timestampDefect(pts: pts)
        #expect(reason != nil)
        #expect(reason?.contains("duplicate") == true)
    }

    @Test func timestampDefectIgnoresTooFewFrames() {
        #expect(ExportEngine.timestampDefect(pts: [0.0, 0.04]) == nil)
    }

    private func dirtySource(count: Int, dupAt: Int) -> [Double] {
        var pts: [Double] = []
        var t = 0.0
        for i in 0..<count {
            pts.append(t)
            if i == dupAt { continue }
            t += (i == dupAt + 2) ? 0.08 : 0.04
        }
        return pts
    }

    @Test func aFaithfulCopyOfAnIrregularSourcePasses() {
        let src = dirtySource(count: 120, dupAt: 50)
        let plan = [PlannedSegment(kind: .copy, range: 0..<100),
                    PlannedSegment(kind: .reEncode, range: 100..<110)]
        var pts = Array(src[0..<100])
        let tail0 = src[99] + 0.04
        pts += (0..<10).map { tail0 + 0.04 * Double($0) }
        #expect(ExportEngine.timestampDefect(pts: pts) != nil)
        #expect(ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src) == nil)
    }

    @Test func theReMaterializedAnomalyMayDriftUpToThreeIntervals() {
        let src = dirtySource(count: 120, dupAt: 50)
        let plan = [PlannedSegment(kind: .copy, range: 0..<100),
                    PlannedSegment(kind: .reEncode, range: 100..<110)]
        var drifted = dirtySource(count: 120, dupAt: 53)
        drifted = Array(drifted[0..<100]) + (0..<10).map { drifted[99] + 0.04 * Double($0 + 1) }
        #expect(ExportEngine.timestampDefect(pts: drifted, plan: plan, sourcePts: src) == nil)
        var tooFar = dirtySource(count: 120, dupAt: 56)
        tooFar = Array(tooFar[0..<100]) + (0..<10).map { tooFar[99] + 0.04 * Double($0 + 1) }
        #expect(ExportEngine.timestampDefect(pts: tooFar, plan: plan, sourcePts: src) != nil)
    }

    @Test func outerEdgesOfThePieceAreNotSeams() {
        var src = (0..<100).map { 0.04 * Double($0) }
        src[99] = src[98] + 0.08
        let plan = [PlannedSegment(kind: .copy, range: 0..<100)]
        #expect(ExportEngine.timestampDefect(pts: src, plan: plan, sourcePts: src) == nil)
        let clean = (0..<100).map { 0.04 * Double($0) }
        #expect(ExportEngine.timestampDefect(pts: src, plan: plan, sourcePts: clean) != nil)
        let interior = [PlannedSegment(kind: .copy, range: 0..<50),
                        PlannedSegment(kind: .reEncode, range: 50..<100)]
        var seamed = (0..<100).map { 0.04 * Double($0) }
        seamed[49] = seamed[48] + 0.08
        #expect(ExportEngine.timestampDefect(pts: seamed, plan: interior, sourcePts: seamed) != nil)
    }

    @Test func outputCountsReanchorCopySpansAfterARepairedSegment() {
        let src = dirtySource(count: 30, dupAt: 15)
        let z = DamageZone(start: 0.1, end: 0.2, affectsVideo: true)
        let plan = [PlannedSegment(kind: .reEncode, range: 0..<10, damage: [z]),
                    PlannedSegment(kind: .copy, range: 10..<25)]
        var pts = (0..<8).map { 0.04 * Double($0) }
        var t = pts.last! + 0.04
        for i in 10..<25 {
            pts.append(t)
            if i == 15 { continue }
            t += (i == 17) ? 0.08 : 0.04
        }
        #expect(ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src) != nil)
        #expect(ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src,
                                             outputCounts: [8, 15]) == nil)
    }

    @Test func anAnomalyTheSourceDoesNotHaveStillFails() {
        let src = (0..<120).map { 0.04 * Double($0) }
        let plan = [PlannedSegment(kind: .copy, range: 0..<100),
                    PlannedSegment(kind: .reEncode, range: 100..<110)]
        var pts = (0..<110).map { 0.04 * Double($0) }
        pts[50] = pts[49]
        let reason = ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src)
        #expect(reason?.contains("duplicate") == true)
    }

    @Test func aMatchingKindIsRequiredNotJustAnyAnomaly() {
        let src = dirtySource(count: 120, dupAt: 50)
        let plan = [PlannedSegment(kind: .copy, range: 0..<100)]
        var pts = Array(src[0..<100])
        pts[20] = pts[19]
        #expect(ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src) != nil)
    }

    @Test func seamAndSegmentEdgeWindowsStayStrict() {
        let plan = [PlannedSegment(kind: .copy, range: 0..<100),
                    PlannedSegment(kind: .reEncode, range: 100..<110)]
        var src = (0..<120).map { 0.04 * Double($0) }
        for j in 100..<120 { src[j] += 0.04 }
        var pts = Array(src[0..<100])
        pts += (0..<10).map { src[100] + 0.04 * Double($0) }
        let reason = ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src)
        #expect(reason?.contains("gap") == true)
        var clean = (0..<110).map { 0.04 * Double($0) }
        for j in 100..<110 { clean[j] += 0.04 }
        #expect(ExportEngine.timestampDefect(pts: clean, plan: plan,
                                             sourcePts: (0..<120).map { 0.04 * Double($0) }) != nil)
        let edgy = dirtySource(count: 120, dupAt: 97)
        var edgyPts = Array(edgy[0..<100])
        edgyPts += (0..<10).map { edgy[99] + 0.04 * Double($0 + 1) }
        #expect(ExportEngine.timestampDefect(pts: edgyPts, plan: plan, sourcePts: edgy) != nil)
    }

    @Test func reEncodedSegmentsKeepStrictUniformity() {
        let src = dirtySource(count: 120, dupAt: 50)
        let plan = [PlannedSegment(kind: .copy, range: 0..<100),
                    PlannedSegment(kind: .reEncode, range: 100..<110)]
        var pts = Array(src[0..<100])
        pts += (0..<10).map { src[99] + 0.04 * Double($0 + 1) }
        pts[105] = pts[104]
        let reason = ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src)
        #expect(reason?.contains("duplicate") == true)
    }

    @Test func anEmptyPlanFallsBackToStrictUniformity() {
        let src = dirtySource(count: 120, dupAt: 50)
        let pts = Array(src[0..<100])
        #expect(ExportEngine.timestampDefect(pts: pts, plan: [], sourcePts: src) != nil)
    }
}

struct PerTrackAudioCodecTests {
    private let src = URL(fileURLWithPath: "/tmp/clip.mkv")
    private let out = URL(fileURLWithPath: "/tmp/out.mkv")

    private func item() -> ExportItem {
        ExportItem(source: src, audioStart: 0, audioEnd: 10, audioSources: [.stream(0), .stream(1)])
    }

    @Test func tracksWithOwnEncodersEmitPerStreamCodecFlags() {
        let tracks = [
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 1, encoder: "mp2"),
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2, encoder: "ac3"),
        ]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: [item()], tracks: tracks,
                                                  audioCodec: "aac", output: out)
        #expect(args.contains("-c:a:0") && args[args.firstIndex(of: "-c:a:0")! + 1] == "mp2")
        #expect(args.contains("-c:a:1") && args[args.firstIndex(of: "-c:a:1")! + 1] == "ac3")
        #expect(!args.contains("-c:a"))
        #expect(args.contains("-b:a"))
    }

    @Test func aTrackWithoutItsOwnEncoderTakesTheExportWideCodec() {
        let tracks = [
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2, encoder: "mp2"),
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2),
        ]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: [item()], tracks: tracks,
                                                  audioCodec: "aac", output: out)
        #expect(args[args.firstIndex(of: "-c:a:1")! + 1] == "aac")
    }

    @Test func withoutPerTrackEncodersTheValidatedSingleCodecShapeIsUnchanged() {
        let tracks = [
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2),
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2),
        ]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: [item()], tracks: tracks,
                                                  audioCodec: "mp2", output: out)
        let i = args.firstIndex(of: "-c:a")
        #expect(i != nil && args[i! + 1] == "mp2")
        #expect(!args.contains("-c:a:0"))
    }
}

struct SeparateFileNamingTests {
    @Test func threeClipsGetTwoDigitPrefixesInTimelineOrder() {
        let names = ExportEngine.separateFileNames(
            clipNames: ["alpha.mkv", "bravo.mkv", "charlie.mkv"], ext: "ts")
        #expect(names == ["01 alpha.ts", "02 bravo.ts", "03 charlie.ts"])
    }

    @Test func aSingleClipIsStillPrefixed() {
        let names = ExportEngine.separateFileNames(clipNames: ["only.mp4"], ext: "mp4")
        #expect(names == ["01 only.mp4"])
    }

    @Test func aHundredClipsWidenThePrefixToThreeDigits() {
        let names = ExportEngine.separateFileNames(
            clipNames: (1...100).map { "clip\($0).mpg" }, ext: "ts")
        #expect(names.first == "001 clip1.ts")
        #expect(names.last == "100 clip100.ts")
    }

    @Test func ninetyNineClipsKeepTwoDigits() {
        let names = ExportEngine.separateFileNames(
            clipNames: (1...99).map { "c\($0).ts" }, ext: "ts")
        #expect(names.first == "01 c1.ts")
        #expect(names.last == "99 c99.ts")
    }

    @Test func slashesAndColonsAreReplaced() {
        let names = ExportEngine.separateFileNames(clipNames: ["AM/PM: late.mkv"], ext: "mp4")
        #expect(names == ["01 AM-PM- late.mp4"])
    }

    @Test func duplicateClipNamesStayDistinctViaThePrefix() {
        let names = ExportEngine.separateFileNames(clipNames: ["same.ts", "same.ts"], ext: "ts")
        #expect(names == ["01 same.ts", "02 same.ts"])
        #expect(Set(names).count == names.count)
    }

    @Test func aForgedCollisionGetsASuffix() {
        var taken: Set<String> = ["01 same.ts"]
        let name = ExportEngine.separateFileName(
            clipName: "same.mkv", position: 1, count: 1, ext: "ts", taken: &taken)
        #expect(name == "01 same-2.ts")
        #expect(taken.contains("01 same-2.ts"))
    }

    @Test func anEmptyStemFallsBackToClip() {
        let names = ExportEngine.separateFileNames(clipNames: [""], ext: "mp4")
        #expect(names == ["01 Clip.mp4"])
    }
}

struct ExportSourceCollisionTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs77-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func touch(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
    }

    @Test func identicalPathIsTheSameFile() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("clip.ts"); touch(a)
        #expect(ExportEngine.denotesSameFile(a, a))
    }

    @Test func distinctFilesAreNotTheSame() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.ts"); touch(a)
        let b = dir.appendingPathComponent("b.ts"); touch(b)
        #expect(!ExportEngine.denotesSameFile(a, b))
    }

    @Test func aSymlinkResolvesToItsTarget() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.ts"); touch(real)
        let link = dir.appendingPathComponent("link.ts")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ExportEngine.denotesSameFile(link, real))
    }

    @Test func aHardLinkHasTheSameFileIdentity() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.ts"); touch(real)
        let hard = dir.appendingPathComponent("hard.ts")
        try FileManager.default.linkItem(at: real, to: hard)
        #expect(ExportEngine.denotesSameFile(hard, real))
    }

    @Test func aNotYetCreatedDestinationInASymlinkedFolderCollides() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let realDir = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let linkDir = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        let source = realDir.appendingPathComponent("clip.ts"); touch(source)
        let dest = linkDir.appendingPathComponent("clip.ts")
        #expect(ExportEngine.denotesSameFile(dest, source))
    }

    private func item(source: URL, name: String,
                      audio: [ExportEngine.AudioSource?] = [.stream(0)]) -> ExportItem {
        ExportItem(source: source, displayName: name, audioSources: audio)
    }

    @Test func connectRefusesWhenTheDestinationIsASource() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("clip.ts"); touch(source)
        var settings = OutputSettings(); settings.mode = .connect
        let items = [item(source: source, name: "Clip A")]
        let outputs = ExportEngine.plannedOutputs(items: items, settings: settings,
                                                  ext: "ts", audioCodec: "aac", to: source)
        do {
            try ExportEngine.assertNoSourceCollision(items: items, outputs: outputs)
            Issue.record("expected destinationIsSource")
        } catch let error as ExportError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("Clip A"))
            #expect(message.contains(source.path))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func connectAllowsADistinctDestination() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("clip.ts"); touch(source)
        let dest = dir.appendingPathComponent("out.ts")
        var settings = OutputSettings(); settings.mode = .connect
        let items = [item(source: source, name: "Clip A")]
        let outputs = ExportEngine.plannedOutputs(items: items, settings: settings,
                                                  ext: "ts", audioCodec: "aac", to: dest)
        try ExportEngine.assertNoSourceCollision(items: items, outputs: outputs)
    }

    @Test func separateRefusesWhenAGeneratedPathIsASource() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("01 clip.ts"); touch(source)
        var settings = OutputSettings(); settings.mode = .separate
        let items = [item(source: source, name: "clip.ts")]
        let outputs = ExportEngine.plannedOutputs(items: items, settings: settings,
                                                  ext: "ts", audioCodec: "aac", to: dir)
        do {
            try ExportEngine.assertNoSourceCollision(items: items, outputs: outputs)
            Issue.record("expected destinationIsSource")
        } catch let error as ExportError {
            #expect((error.errorDescription ?? "").contains(source.path))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func aCollisionWithAnExternalAudioSourceIsCaught() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("video.ts"); touch(video)
        let external = dir.appendingPathComponent("audio.wav"); touch(external)
        var settings = OutputSettings(); settings.mode = .connect
        let items = [item(source: video, name: "Clip A",
                          audio: [.external(external, stream: 0)])]
        let outputs = ExportEngine.plannedOutputs(items: items, settings: settings,
                                                  ext: "ts", audioCodec: "aac", to: external)
        do {
            try ExportEngine.assertNoSourceCollision(items: items, outputs: outputs)
            Issue.record("expected destinationIsSource")
        } catch let error as ExportError {
            #expect((error.errorDescription ?? "").contains(external.path))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}

struct AudioLegLengthGuardTests {
    private let src = URL(fileURLWithPath: "/tmp/clip.mkv")
    private let stereoTrack = AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2)

    private func lengthless(audio: [ExportEngine.AudioSource?],
                            ownTracks: [AudioCodecPolicy.OutputAudioTrack]? = nil) -> ExportItem {
        ExportItem(source: src, displayName: "Clip A", audioStart: 1.0, audioEnd: nil,
                   audioSources: audio, ownTracks: ownTracks)
    }

    @Test func aSilenceLegWithNoKnownLengthRefusesTheExport() {
        let items = [lengthless(audio: [.stream(0)])]
        do {
            try ExportEngine.assertAudioLegLengthsKnown(items: items,
                                                        tracks: [stereoTrack, stereoTrack],
                                                        mode: .connect)
            Issue.record("expected unknownSilenceLength")
        } catch let error as ExportError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("Clip A"))
            #expect(message.contains("track 2"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func anExplicitlyNilSourceWithNoKnownLengthRefusesToo() {
        let items = [lengthless(audio: [nil])]
        #expect(throws: ExportError.self) {
            try ExportEngine.assertAudioLegLengthsKnown(items: items, tracks: [stereoTrack],
                                                        mode: .connect)
        }
    }

    @Test func aRealLegWithNoKnownLengthIsAllowed() throws {
        let items = [lengthless(audio: [.stream(0), .stream(1)])]
        try ExportEngine.assertAudioLegLengthsKnown(items: items, tracks: [stereoTrack, stereoTrack],
                                                    mode: .connect)
    }

    @Test func aKnownLengthAllowsSilenceLegs() throws {
        let items = [ExportItem(source: src, displayName: "Clip A", audioStart: 0, audioEnd: 2,
                                audioSources: [.stream(0)])]
        try ExportEngine.assertAudioLegLengthsKnown(items: items, tracks: [stereoTrack, stereoTrack],
                                                    mode: .connect)
    }

    @Test func separateModeJudgesAClipAgainstItsOwnTracks() throws {
        let items = [lengthless(audio: [.stream(0)], ownTracks: [stereoTrack])]
        try ExportEngine.assertAudioLegLengthsKnown(items: items, tracks: [stereoTrack, stereoTrack],
                                                    mode: .separate)
        #expect(throws: ExportError.self) {
            try ExportEngine.assertAudioLegLengthsKnown(items: items, tracks: [stereoTrack, stereoTrack],
                                                        mode: .connect)
        }
    }
}

struct FieldCodedCopyCutExportTests {
    private let trimmed = [PlannedSegment(kind: .copy, range: 100..<2000, outCutKeyframe: 2010)]

    @Test func aFieldCodedCutAlwaysProducesTsPieces() {
        #expect(ExportEngine.pieceExtension(container: "mkv", fieldCoded: true, plan: trimmed) == "ts")
        #expect(ExportEngine.pieceExtension(container: "mp4", fieldCoded: true, plan: trimmed) == "ts")
        #expect(ExportEngine.pieceExtension(container: "ts", fieldCoded: true, plan: trimmed) == "ts")
    }

    @Test func aSingleEndedTrimIsStillACutAndStillTs() {
        let headCut = [PlannedSegment(kind: .copy, range: 100..<2000, outCutKeyframe: nil)]
        #expect(ExportEngine.pieceExtension(container: "mkv", fieldCoded: true, plan: headCut) == "ts")
        let tailCut = [PlannedSegment(kind: .copy, range: 0..<2000, outCutKeyframe: 2010)]
        #expect(ExportEngine.pieceExtension(container: "mkv", fieldCoded: true, plan: tailCut) == "ts")
    }

    @Test func aWholeClipFieldCodedKeepStaysOnThePlainRemuxPath() {
        let whole = [PlannedSegment(kind: .copy, range: 0..<2000, outCutKeyframe: nil)]
        #expect(ExportEngine.pieceExtension(container: "mkv", fieldCoded: true, plan: whole) == "mkv")
        #expect(ExportEngine.pieceExtension(container: "mp4", fieldCoded: true, plan: whole) == "mp4")
        #expect(ExportEngine.pieceExtension(container: "ts", fieldCoded: true, plan: whole) == "ts")
    }

    @Test func theWholeClipCopyShapeIsOneUncutCopySegment() {
        #expect(ExportEngine.isWholeClipCopy(
            [PlannedSegment(kind: .copy, range: 0..<2000, outCutKeyframe: nil)]))
        #expect(!ExportEngine.isWholeClipCopy(
            [PlannedSegment(kind: .copy, range: 100..<2000, outCutKeyframe: nil)]))
        #expect(!ExportEngine.isWholeClipCopy(
            [PlannedSegment(kind: .copy, range: 0..<2000, outCutKeyframe: 2010)]))
        #expect(!ExportEngine.isWholeClipCopy(
            [PlannedSegment(kind: .reEncode, range: 0..<2000, outCutKeyframe: nil)]))
        #expect(!ExportEngine.isWholeClipCopy(
            [PlannedSegment(kind: .copy, range: 0..<1000, outCutKeyframe: 1000),
             PlannedSegment(kind: .copy, range: 1000..<2000, outCutKeyframe: nil)]))
        #expect(!ExportEngine.isWholeClipCopy([]))
    }

    @Test func nonFieldCodedClipsKeepTheContainerExtension() {
        #expect(ExportEngine.pieceExtension(container: "mkv", fieldCoded: false, plan: trimmed) == "mkv")
        #expect(ExportEngine.pieceExtension(container: "mp4", fieldCoded: false, plan: trimmed) == "mp4")
    }

    @Test func theMp4TimescalePinNeverReachesATsPiece() {
        let src = URL(fileURLWithPath: "/tmp/clip.ts")
        let plan = SegmentPlan(inFrame: 100, outFrame: 1999, inSegmentTime: 4.0, outSegmentTime: 80.0)
        let mp4Cut = ExportEngine.cutArguments(source: src, plan: plan,
                                               segmentPattern: "/tmp/p_%03d.mp4", trackTimescale: 450000)
        #expect(mp4Cut.contains("-segment_format_options"))
        let tsCut = ExportEngine.cutArguments(source: src, plan: plan,
                                              segmentPattern: "/tmp/p_%03d.ts")
        #expect(!tsCut.contains("-segment_format_options"))
        #expect(!tsCut.joined().contains("video_track_timescale"))
    }

    private func item(_ path: String, fieldCoded: Bool = false,
                      segments: [PlannedSegment]? = nil) -> ExportItem {
        let index = FrameIndex(pts: [0.0, 0.04, 0.08, 0.12],
                               keyframeFlags: [true, false, false, false])
        var item = ExportItem(source: URL(fileURLWithPath: path),
                              segments: segments ?? [PlannedSegment(kind: .copy, range: 0..<2)],
                              index: index)
        item.fieldCoded = fieldCoded
        return item
    }

    @Test func aFieldCodedItemForcesEveryPieceOfAConnectJoinToTs() {
        let whole = [PlannedSegment(kind: .copy, range: 0..<4, outCutKeyframe: nil)]
        let items = [item("/tmp/paff.ts", fieldCoded: true),
                     item("/tmp/plain.mkv"),
                     item("/tmp/wholekeep.mkv", segments: whole)]
        #expect(ExportEngine.pieceExtensions(container: "mkv", mode: .connect, items: items)
                == ["ts", "ts", "ts"])
        #expect(ExportEngine.pieceExtensions(container: "mp4", mode: .connect, items: items)
                == ["ts", "ts", "ts"])
    }

    @Test func withoutAFieldCodedItemTheJoinKeepsPerItemContainers() {
        let items = [item("/tmp/a.ts"), item("/tmp/b.ts")]
        #expect(ExportEngine.pieceExtensions(container: "mkv", mode: .connect, items: items)
                == ["mkv", "mkv"])
    }

    @Test func aSingleClipConnectAndSeparateItemsKeepThePerItemRule() {
        let whole = [PlannedSegment(kind: .copy, range: 0..<4, outCutKeyframe: nil)]
        let cut = [PlannedSegment(kind: .copy, range: 1..<3, outCutKeyframe: 3)]
        let separate = [item("/tmp/paff.ts", fieldCoded: true, segments: cut),
                        item("/tmp/wholepaff.ts", fieldCoded: true, segments: whole),
                        item("/tmp/plain.mkv")]
        #expect(ExportEngine.pieceExtensions(container: "mkv", mode: .separate, items: separate)
                == ["ts", "mkv", "mkv"])
        let lone = [item("/tmp/wholepaff.ts", fieldCoded: true, segments: whole)]
        #expect(ExportEngine.pieceExtensions(container: "mkv", mode: .connect, items: lone)
                == ["mkv"])
    }

    @Test func onlyFieldCodedEntriesDropTheirConcatDurationDirective() {
        let leading = ExportEngine.crossClipDurations(items: [item("/tmp/a.ts", fieldCoded: true),
                                                              item("/tmp/b.ts")])
        #expect(leading.count == 2)
        #expect(leading[0] == nil)
        #expect(leading[1] == nil)
        let trailing = ExportEngine.crossClipDurations(items: [item("/tmp/a.ts"),
                                                               item("/tmp/b.ts", fieldCoded: true)])
        #expect(trailing.count == 2)
        #expect(abs((trailing[0] ?? -1) - 0.08) < 1e-9)
        #expect(trailing[1] == nil)
        let sandwich = ExportEngine.crossClipDurations(items: [item("/tmp/a.ts", fieldCoded: true),
                                                               item("/tmp/b.ts"),
                                                               item("/tmp/c.ts", fieldCoded: true)])
        #expect(sandwich.count == 3)
        #expect(sandwich[0] == nil)
        #expect(abs((sandwich[1] ?? -1) - 0.08) < 1e-9)
        #expect(sandwich[2] == nil)
        let pieces = [URL(fileURLWithPath: "/tmp/a_piece.ts"), URL(fileURLWithPath: "/tmp/b_piece.ts")]
        #expect(ExportEngine.concatListContents(pieces: pieces, durations: leading)
                == "file '/tmp/a_piece.ts'\nfile '/tmp/b_piece.ts'\n")
        #expect(ExportEngine.concatListContents(pieces: pieces, durations: trailing)
                == "file '/tmp/a_piece.ts'\nduration 0.08\nfile '/tmp/b_piece.ts'\n")
    }

    @Test func withoutAFieldCodedPieceTheDirectivesAreUnchanged() {
        let durations = ExportEngine.crossClipDurations(items: [item("/tmp/a.ts"), item("/tmp/b.ts")])
        #expect(durations.count == 2)
        #expect(abs((durations[0] ?? -1) - 0.08) < 1e-9)
        #expect(durations[1] == nil)
    }

    private func video() -> VideoProperties {
        VideoProperties(codec: "h264", profile: nil, level: nil, width: 704, height: 528,
                        frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: nil,
                        sampleAspectRatio: nil, colorPrimaries: nil, colorTransfer: nil,
                        colorRange: nil)
    }

    @Test func theJoinsDepthIsTheDeepestCopiedPiece() {
        let src = URL(fileURLWithPath: "/tmp/a.mkv")
        func copying(_ depth: Int?) -> ExportItem {
            ExportItem(source: src, segments: [PlannedSegment(kind: .copy, range: 0..<4)],
                       sourceReorderDepth: depth)
        }
        func reencodingOnly(_ depth: Int?) -> ExportItem {
            ExportItem(source: src, segments: [PlannedSegment(kind: .reEncode, range: 0..<4)],
                       sourceReorderDepth: depth)
        }
        #expect(ExportEngine.joinReorderDepth(items: [copying(2)]) == 2)
        #expect(ExportEngine.joinReorderDepth(items: [copying(1), copying(2)]) == 2)
        #expect(ExportEngine.joinReorderDepth(items: [copying(1)]) == 1)
        #expect(ExportEngine.joinReorderDepth(items: [copying(nil)]) == 1)
        #expect(ExportEngine.joinReorderDepth(items: [reencodingOnly(2)]) == 1)
        let conformed = ExportItem(source: src, sourceReorderDepth: 2,
                                   conform: ConformEngine.VideoConform(
                                       sourceVideo: video(), targetVideo: video()))
        #expect(ExportEngine.joinReorderDepth(items: [conformed, reencodingOnly(2)]) == 1)
        #expect(ExportEngine.joinReorderDepth(items: [conformed, copying(2)]) == 2)
    }

    @Test func anItemsPiecesFollowTheJoinOnlyWhenItsFirstPieceIsOurs() {
        let src = URL(fileURLWithPath: "/tmp/a.mkv")
        let copyFirst = ExportItem(source: src,
                                   segments: [PlannedSegment(kind: .copy, range: 0..<4),
                                              PlannedSegment(kind: .reEncode, range: 4..<8)],
                                   sourceReorderDepth: 1)
        #expect(ExportEngine.pieceReorderDepth(item: copyFirst, joinDepth: 2) == 1)
        let reencodeFirst = ExportItem(source: src,
                                       segments: [PlannedSegment(kind: .reEncode, range: 0..<4),
                                                  PlannedSegment(kind: .copy, range: 4..<8)],
                                       sourceReorderDepth: 2)
        #expect(ExportEngine.pieceReorderDepth(item: reencodeFirst, joinDepth: 2) == 2)
        let conformed = ExportItem(source: src, conform: ConformEngine.VideoConform(
            sourceVideo: video(), targetVideo: video()))
        #expect(ExportEngine.pieceReorderDepth(item: conformed, joinDepth: 2) == 2)
        #expect(ExportEngine.pieceReorderDepth(item: conformed, joinDepth: 1) == 1)
        let veryDeep = ExportItem(source: src,
                                  segments: [PlannedSegment(kind: .reEncode, range: 0..<4)],
                                  sourceReorderDepth: 4)
        #expect(ExportEngine.pieceReorderDepth(item: veryDeep, joinDepth: 4)
            == EncoderSelection.deepestEncodableReorderDepth)
    }

    @Test func plannedOutputsNameTheContainerExtensionForAFieldCodedClip() {
        var settings = OutputSettings(); settings.mode = .separate
        let items = [item("/tmp/paff.ts", fieldCoded: true), item("/tmp/plain.ts")]
        let outputs = ExportEngine.plannedOutputs(items: items, settings: settings,
                                                  ext: "mkv", audioCodec: "aac",
                                                  to: URL(fileURLWithPath: "/tmp/out"))
        #expect(outputs.count == 2)
        #expect(outputs.allSatisfy { $0.url.pathExtension == "mkv" })
    }
}
