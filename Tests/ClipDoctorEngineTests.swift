import Testing
import Foundation
@testable import ClipStitcher

struct ClipDoctorEngineTests {
    private let src = URL(fileURLWithPath: "/vol/captures/race.ts")

    @Test func repairedSiblingSitsNextToSourceInSameContainer() {
        #expect(ClipDoctorEngine.repairedSibling(of: src).path == "/vol/captures/race_repaired.ts")
    }

    @Test func repairedSiblingKeepsTheStemEvenWithInteriorDots() {
        let dotted = URL(fileURLWithPath: "/vol/captures/2026.06.07.race.ts")
        #expect(ClipDoctorEngine.repairedSibling(of: dotted).lastPathComponent == "2026.06.07.race_repaired.ts")
    }

    @Test func repairedMuxCopiesVideoAndRebuildsHEAACInItsOwnCodec() {
        let track = ClipDoctorEngine.AudioTrack(
            streamIndex: 0, sampleRate: 48000, encoder: "aac_at", bitrate: 95970, heAAC: true)
        let args = ClipDoctorEngine.repairedMuxArguments(
            videoPiece: URL(fileURLWithPath: "/tmp/v.ts"), source: src, tracks: [track],
            output: URL(fileURLWithPath: "/tmp/out.ts"))
        #expect(args.firstIndex(of: "/tmp/v.ts")! < args.firstIndex(of: src.path)!)
        #expect(args[args.firstIndex(of: "-max_error_rate")! + 1] == "1.0")
        #expect(args.contains("-c:v") && args.contains("copy"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[1:a:0]aresample=48000:async=1[a0]")
        #expect(!fc.contains("first_pts"))
        #expect(args[args.firstIndex(of: "-c:a:0")! + 1] == "aac_at")
        #expect(args[args.firstIndex(of: "-profile:a:0")! + 1] == "4")
        #expect(args[args.firstIndex(of: "-b:a:0")! + 1] == "95970")
        #expect(args.last == "/tmp/out.ts")
    }

    @Test func repairedMuxPreservesTrackOrderAndOmitsProfileForNonHE() {
        let tracks = [
            ClipDoctorEngine.AudioTrack(streamIndex: 0, sampleRate: 48000, encoder: "mp2", bitrate: 384000, heAAC: false),
            ClipDoctorEngine.AudioTrack(streamIndex: 1, sampleRate: 48000, encoder: "mp2", bitrate: 192000, heAAC: false),
        ]
        let args = ClipDoctorEngine.repairedMuxArguments(
            videoPiece: URL(fileURLWithPath: "/tmp/v.ts"), source: src, tracks: tracks,
            output: URL(fileURLWithPath: "/tmp/out.ts"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[1:a:0]aresample=48000:async=1[a0];[1:a:1]aresample=48000:async=1[a1]")
        #expect(args.firstIndex(of: "[a0]")! < args.firstIndex(of: "[a1]")!)
        #expect(!args.contains("-profile:a:0") && !args.contains("-profile:a:1"))
        #expect(args[args.firstIndex(of: "-b:a:0")! + 1] == "384000")
        #expect(args[args.firstIndex(of: "-b:a:1")! + 1] == "192000")
    }

    @Test func heAACResolvesToAudioToolboxAtSourceBitrate() {
        let detail = MediaProbe.AudioStreamDetail(
            codecName: "aac", profile: "HE-AAC", sampleRate: 48000, channels: 2, bitrate: 95970)
        let track = ClipDoctorEngine.audioTrack(from: detail, audioStreamIndex: 0)
        #expect(track.encoder == "aac_at")
        #expect(track.heAAC)
        #expect(track.bitrate == 95970)
        #expect(track.sampleRate == 48000)
    }

    @Test func lcAACResolvesToTheNativeEncoder() {
        let detail = MediaProbe.AudioStreamDetail(
            codecName: "aac", profile: "LC", sampleRate: 48000, channels: 2, bitrate: 128000)
        let track = ClipDoctorEngine.audioTrack(from: detail, audioStreamIndex: 1)
        #expect(track.encoder == "aac")
        #expect(!track.heAAC)
        #expect(track.streamIndex == 1)
    }

    @Test func mp2ResolvesToItsOwnEncoder() {
        let detail = MediaProbe.AudioStreamDetail(
            codecName: "mp2", profile: nil, sampleRate: 48000, channels: 2, bitrate: 384000)
        let track = ClipDoctorEngine.audioTrack(from: detail, audioStreamIndex: 0)
        #expect(track.encoder == "mp2")
        #expect(!track.heAAC)
    }

    @Test func missingBitrateFallsBackByChannelCount() {
        let stereo = MediaProbe.AudioStreamDetail(
            codecName: "aac", profile: "LC", sampleRate: 48000, channels: 2, bitrate: nil)
        let mono = MediaProbe.AudioStreamDetail(
            codecName: "aac", profile: "LC", sampleRate: 48000, channels: 1, bitrate: nil)
        #expect(ClipDoctorEngine.audioTrack(from: stereo, audioStreamIndex: 0).bitrate == 128_000)
        #expect(ClipDoctorEngine.audioTrack(from: mono, audioStreamIndex: 0).bitrate == 96_000)
    }

    @Test func aReScanWithNoZonesIsClean() {
        let v = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: true, survivingZones: [])
        #expect(v.clean)
        #expect(v.outcome == .clean)
        #expect(v.message.contains("re-scanned clean"))
    }

    @Test func survivingZonesAreASoftWarningNamingThem() {
        let zones = [DamageZone(start: 65, end: 66, affectsVideo: true)]
        let v = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: true, survivingZones: zones)
        #expect(!v.clean)
        #expect(v.outcome == .zonesRemain)
        #expect(v.message.contains("1 damage zone remains"))
        #expect(v.message.contains("1:05"))
    }

    @Test func manySurvivingZonesAreCountedAndCapped() {
        let zones = (0..<8).map { DamageZone(start: Double($0) * 100, end: Double($0) * 100 + 1, affectsVideo: true) }
        let v = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: true, survivingZones: zones)
        #expect(v.message.contains("8 damage zones remain"))
        #expect(v.message.contains("…"))
    }

    @Test func anUnscannedOutputIsInconclusiveNotDiscarded() {
        let v = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: false, survivingZones: [])
        #expect(v.outcome == .inconclusive)
        #expect(v.message.contains("could not be re-scanned"))
    }

    @Test func aCancelledVerifyIsNotVerifiedAndStatesBothFacts() {
        let v = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: false, cancelled: true, survivingZones: [])
        #expect(v.outcome == .notVerified)
        #expect(!v.clean)
        #expect(v.message.contains("saved the file"))
        #expect(v.message.contains("cancelled"))
    }

    @Test func aCancelledVerifyIsDistinctFromAnInvoluntaryReScanFailure() {
        let cancelled = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: false, cancelled: true, survivingZones: [])
        let failed = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: false, cancelled: false, survivingZones: [])
        #expect(cancelled.outcome == .notVerified)
        #expect(failed.outcome == .inconclusive)
        #expect(cancelled.outcome != failed.outcome)
        #expect(cancelled.message != failed.message)
    }

    @Test func verifyOutputReportsACancelAsNotVerifiedNotInconclusive() async {
        let task = Task { () -> ClipDoctorEngine.Verdict in
            await ClipDoctorEngine.verifyOutput(
                URL(fileURLWithPath: "/nonexistent/out.ts"), clipName: "race", expectedDuration: 10)
        }
        task.cancel()
        let verdict = await task.value
        #expect(verdict.outcome == .notVerified)
    }

    @Test func noOtherStreamsHasNoNotice() {
        #expect(ClipDoctorEngine.omittedStreamsNotice([]) == nil)
    }

    @Test func oneSubtitleStreamReadsSingular() {
        let notice = ClipDoctorEngine.omittedStreamsNotice([
            MediaProbe.OtherStream(kind: "subtitle", codecName: "dvb_teletext")])
        #expect(notice == "1 subtitle stream won’t be carried into the repaired copy — Clip Doctor copies video and audio only.")
    }

    @Test func manyKindsAreCountedAndListedInContainerOrder() {
        let notice = ClipDoctorEngine.omittedStreamsNotice([
            MediaProbe.OtherStream(kind: "subtitle", codecName: "dvb_subtitle"),
            MediaProbe.OtherStream(kind: "subtitle", codecName: "dvb_teletext"),
            MediaProbe.OtherStream(kind: "data", codecName: "bin_data"),
        ])
        #expect(notice?.hasPrefix("2 subtitle streams and 1 data stream won’t be carried") == true)
    }

    @Test func parseNonAVStreamsKeepsOnlyNonAV() throws {
        let json = Data("""
        {"streams":[
          {"codec_type":"video","codec_name":"h264"},
          {"codec_type":"audio","codec_name":"aac"},
          {"codec_type":"subtitle","codec_name":"dvb_teletext"},
          {"codec_type":"data","codec_name":"bin_data"}
        ]}
        """.utf8)
        let streams = try MediaProbe.parseNonAVStreams(json: json)
        #expect(streams == [
            MediaProbe.OtherStream(kind: "subtitle", codecName: "dvb_teletext"),
            MediaProbe.OtherStream(kind: "data", codecName: "bin_data"),
        ])
    }

    @Test func bannerNamesTheClipAndZoneCount() {
        #expect(ClipDoctorEngine.suggestionBannerText(clipName: "1844", zoneCount: 1)
                == "“1844” has a damage zone. Clip Doctor can repair it.")
        #expect(ClipDoctorEngine.suggestionBannerText(clipName: "1844", zoneCount: 9)
                == "“1844” has 9 damage zones. Clip Doctor can repair it.")
    }

    private func keyframeGridIndex(count: Int = 2495, gop: Int = 12) -> FrameIndex {
        let pts = (0..<count).map { Double($0) * 0.04 }
        let flags = (0..<count).map { $0 % gop == 0 }
        return FrameIndex(pts: pts, keyframeFlags: flags)
    }

    @Test func damageToEOFCopiesToTheSeamKeyframeThenReencodesToTheEnd() {
        let index = keyframeGridIndex()
        let zones = [DamageZone(start: 30.0, end: 31.0, affectsVideo: true)]
        let segments: [PlannedSegment] = [
            PlannedSegment(kind: .copy, range: 0..<746, outCutKeyframe: 756),
            PlannedSegment(kind: .reEncode, range: 746..<860, damage: zones),
            PlannedSegment(kind: .copy, range: 860..<2495),
        ]
        let plan = ClipDoctorEngine.damageToEOFPlan(segments, index: index, zones: zones)
        #expect(plan.count == 2)
        #expect(plan[0].kind == .copy)
        #expect(plan[0].range == 0..<744)
        #expect(plan[1].kind == .reEncode)
        #expect(plan[1].range == 744..<2495)
        #expect(plan[1].outCutKeyframe == nil)
        #expect(plan[1].damage == zones)
    }

    @Test func damageToEOFFoldsEveryVideoZoneIntoOneTailSegment() {
        let index = keyframeGridIndex()
        let z1 = DamageZone(start: 30.0, end: 31.0, affectsVideo: true)
        let z2 = DamageZone(start: 60.0, end: 61.0, affectsVideo: true)
        let audioOnly = DamageZone(start: 90.0, end: 91.0, affectsVideo: false)
        let segments: [PlannedSegment] = [
            PlannedSegment(kind: .copy, range: 0..<744, outCutKeyframe: 744),
            PlannedSegment(kind: .reEncode, range: 744..<860, damage: [z1]),
            PlannedSegment(kind: .copy, range: 860..<1500),
            PlannedSegment(kind: .reEncode, range: 1500..<1600, damage: [z2]),
            PlannedSegment(kind: .copy, range: 1600..<2495),
        ]
        let plan = ClipDoctorEngine.damageToEOFPlan(segments, index: index, zones: [z1, z2, audioOnly])
        #expect(plan.count == 2)
        #expect(plan[0].range == 0..<744)
        #expect(plan[1].range == 744..<2495)
        #expect(plan[1].damage == [z1, z2])
    }

    @Test func damageToEOFWithNoCleanHeadIsAFullReencode() {
        let index = keyframeGridIndex()
        let zones = [DamageZone(start: 0.0, end: 0.2, affectsVideo: true)]
        let segments: [PlannedSegment] = [
            PlannedSegment(kind: .reEncode, range: 0..<2495, damage: zones),
        ]
        let plan = ClipDoctorEngine.damageToEOFPlan(segments, index: index, zones: zones)
        #expect(plan.count == 1)
        #expect(plan[0].kind == .reEncode)
        #expect(plan[0].range == 0..<2495)
    }

    @Test func fieldCodedRepairPairsTheDamageToEOFPlanWithTheMbaffEncoder() {
        let index = keyframeGridIndex()
        let zones = [DamageZone(start: 30.0, end: 31.0, affectsVideo: true)]
        let segments: [PlannedSegment] = [
            PlannedSegment(kind: .copy, range: 0..<746, outCutKeyframe: 756),
            PlannedSegment(kind: .reEncode, range: 746..<860, damage: zones),
            PlannedSegment(kind: .copy, range: 860..<2495),
        ]
        let (plan, encoder) = ClipDoctorEngine.fieldCodedRepair(
            from: segments, index: index, zones: zones, fieldOrder: "tt")
        #expect(plan == ClipDoctorEngine.damageToEOFPlan(segments, index: index, zones: zones))
        #expect(encoder == BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: "tt"))
    }

    @Test func repairPurposeTreatmentFeedsTheFieldCodedCollapse() throws {
        let index = keyframeGridIndex()
        let zone = DamageZone(start: 30.0, end: 31.0, affectsVideo: true)
        var clip = Clip(bookmark: Data(), displayName: "race")
        clip.video = VideoProperties(
            codec: "h264", profile: "High", level: "40", width: 1920, height: 1080,
            frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: "tt",
            sampleAspectRatio: "1:1", colorPrimaries: nil, colorTransfer: nil,
            colorRange: nil)
        clip.fieldCoded = true
        clip.damageZones = [zone]
        let treatment = try ExportPlanner.videoTreatment(
            for: clip, target: nil, index: index, containerStart: 0, purpose: .repair)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments.contains { $0.kind == .reEncode && $0.damage == [zone] })
        let (plan, encoder) = ClipDoctorEngine.fieldCodedRepair(
            from: segments, index: index, zones: [zone], fieldOrder: "tt")
        #expect(plan.count == 2)
        #expect(plan[0].kind == .copy)
        #expect(plan[0].range.lowerBound == 0)
        #expect(plan[1].kind == .reEncode)
        #expect(plan[1].range.upperBound == index.count)
        #expect(plan[1].damage == [zone])
        #expect(encoder == BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: "tt"))
    }

    @Test func fieldCodedRepairIsH264Only() {
        #expect(ClipDoctorEngine.canRepairFieldCoded(codec: "h264"))
        for other in ["hevc", "mpeg2video", "vc1", nil] {
            #expect(!ClipDoctorEngine.canRepairFieldCoded(codec: other))
        }
    }

    @Test func unsupportedFieldCodedCodecMessageNamesH264() {
        let msg = ClipDoctorEngine.DoctorError.unsupportedFieldCodedCodec("hevc").errorDescription ?? ""
        #expect(msg.contains("H.264"))
        #expect(msg.contains("HEVC"))
        for banned in ["fix", "heal", "patch", "error concealment"] {
            #expect(!msg.lowercased().contains(banned))
        }
    }

    @Test func definiteFieldOrderIsOnlyTheFourInterlacedLabels() {
        for ok in ["tt", "tb", "bb", "bt"] {
            #expect(ClipDoctorEngine.isDefiniteFieldOrder(ok))
        }
        for notOk in [nil, "", "unknown", "progressive", "TT", "interlaced"] {
            #expect(!ClipDoctorEngine.isDefiniteFieldOrder(notOk))
        }
    }

    @Test func fieldOrderDetectionArgsRunIdetAtInfoLevelWithAFrameBudget() {
        let args = ClipDoctorEngine.fieldOrderDetectionArguments(source: URL(fileURLWithPath: "/x/y.ts"), frames: 500)
        #expect(args[args.firstIndex(of: "-v")! + 1] == "info")
        #expect(args[args.firstIndex(of: "-vf")! + 1] == "idet")
        #expect(args[args.firstIndex(of: "-frames:v")! + 1] == "500")
        #expect(args.suffix(2) == ["-f", "null"] || args.contains("null"))
        #expect(args.contains("-an"))
    }

    @Test func parseIdetTallyTakesTheLastMultiFrameLine() {
        let stderr = """
        [Parsed_idet_0 @ 0x1] Repeated Fields: Neither:     0 Top:     0 Bottom:     0
        [Parsed_idet_0 @ 0x1] Single frame detection: TFF:     0 BFF:     0 Progressive:     0 Undetermined:     0
        [Parsed_idet_0 @ 0x1] Multi frame detection: TFF:     0 BFF:     0 Progressive:     0 Undetermined:     0
        frame=  202 fps=198 q=-0.0 size=N/A time=00:00:08.04
        [Parsed_idet_0 @ 0x2] Single frame detection: TFF:   501 BFF:     0 Progressive:     0 Undetermined:     0
        [Parsed_idet_0 @ 0x2] Multi frame detection: TFF:   498 BFF:     1 Progressive:     2 Undetermined:     0
        """
        let tally = ClipDoctorEngine.parseIdetTally(stderr)
        #expect(tally == ClipDoctorEngine.IdetTally(tff: 498, bff: 1, progressive: 2, undetermined: 0))
        #expect(ClipDoctorEngine.parseIdetTally("no idet here\nframe=10") == nil)
    }

    @Test func fieldOrderFromIdetDecidesOnlyOnAClearDominantPolarity() {
        #expect(ClipDoctorEngine.fieldOrderFromIdet(.init(tff: 501, bff: 0, progressive: 0, undetermined: 0)) == "tt")
        #expect(ClipDoctorEngine.fieldOrderFromIdet(.init(tff: 2, bff: 480, progressive: 5, undetermined: 3)) == "bb")
        #expect(ClipDoctorEngine.fieldOrderFromIdet(.init(tff: 260, bff: 240, progressive: 0, undetermined: 0)) == nil)
        #expect(ClipDoctorEngine.fieldOrderFromIdet(.init(tff: 40, bff: 10, progressive: 400, undetermined: 50)) == nil)
        #expect(ClipDoctorEngine.fieldOrderFromIdet(.init(tff: 30, bff: 0, progressive: 0, undetermined: 0)) == nil)
    }

    @Test func fieldCodedNoticeWarnsFullReencodeAndScalesTheEstimate() {
        let long = ClipDoctorEngine.fieldCodedReencodeNotice(clipName: "1842", duration: 17_280)
        #expect(long.contains("not bit-for-bit identical"))
        #expect(long.contains("an hour"))
        #expect(long.contains("5 hours"))
        for banned in ["fix", "heal", "patch", "error concealment"] {
            #expect(!long.lowercased().contains(banned))
        }
        #expect(ClipDoctorEngine.fieldCodedReencodeNotice(clipName: "x", duration: 100)
            .contains("a minute or two"))
        #expect(!ClipDoctorEngine.fieldCodedReencodeNotice(clipName: "x", duration: nil)
            .contains("Expect"))
    }
}
