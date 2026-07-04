import Testing
import Foundation
@testable import ClipStitcher

/// The pure core of the Clip Doctor repair-only export (issue #52, ADR-0021): the bounded
/// keyframe-copy command shape, the source-codec audio rebuild mux, the audio-track
/// resolution, the sibling-output naming, and the auto-verify verdict. The recipes
/// themselves were de-risked against the real 1844 capture (#51); these pin the argument
/// shapes and the verdict wording so they can't drift.
struct ClipDoctorEngineTests {
    private let src = URL(fileURLWithPath: "/vol/captures/race.ts")

    // MARK: - Sibling output naming

    @Test func repairedSiblingSitsNextToSourceInSameContainer() {
        #expect(ClipDoctorEngine.repairedSibling(of: src).path == "/vol/captures/race_repaired.ts")
    }

    @Test func repairedSiblingKeepsTheStemEvenWithInteriorDots() {
        let dotted = URL(fileURLWithPath: "/vol/captures/2026.06.07.race.ts")
        #expect(ClipDoctorEngine.repairedSibling(of: dotted).lastPathComponent == "2026.06.07.race_repaired.ts")
    }

    // MARK: - Source-codec audio rebuild mux

    @Test func repairedMuxCopiesVideoAndRebuildsHEAACInItsOwnCodec() {
        let track = ClipDoctorEngine.AudioTrack(
            streamIndex: 0, sampleRate: 48000, encoder: "aac_at", bitrate: 95970, heAAC: true)
        let args = ClipDoctorEngine.repairedMuxArguments(
            videoPiece: URL(fileURLWithPath: "/tmp/v.ts"), source: src, tracks: [track],
            output: URL(fileURLWithPath: "/tmp/out.ts"))
        // Video piece is input 0 (copied), the source is input 1 with -max_error_rate.
        #expect(args.firstIndex(of: "/tmp/v.ts")! < args.firstIndex(of: src.path)!)
        #expect(args[args.firstIndex(of: "-max_error_rate")! + 1] == "1.0")
        #expect(args.contains("-c:v") && args.contains("copy"))
        // Gap-fill resample WITHOUT first_pts=0 (preserve the source priming offset).
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[1:a:0]aresample=48000:async=1[a0]")
        #expect(!fc.contains("first_pts"))
        // HE-AAC fidelity via AudioToolbox's numeric profile.
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
        #expect(args.firstIndex(of: "[a0]")! < args.firstIndex(of: "[a1]")!)   // order preserved
        #expect(!args.contains("-profile:a:0") && !args.contains("-profile:a:1"))
        #expect(args[args.firstIndex(of: "-b:a:0")! + 1] == "384000")
        #expect(args[args.firstIndex(of: "-b:a:1")! + 1] == "192000")
    }

    // MARK: - Audio-track resolution

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

    // MARK: - Auto-verify verdict

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
        #expect(v.message.contains("1:05"))   // formattedClipTime(65)
    }

    @Test func manySurvivingZonesAreCountedAndCapped() {
        let zones = (0..<8).map { DamageZone(start: Double($0) * 100, end: Double($0) * 100 + 1, affectsVideo: true) }
        let v = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: true, survivingZones: zones)
        #expect(v.message.contains("8 damage zones remain"))
        #expect(v.message.contains("…"))      // capped at six shown
    }

    @Test func anUnscannedOutputIsInconclusiveNotDiscarded() {
        let v = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: false, survivingZones: [])
        #expect(v.outcome == .inconclusive)
        #expect(v.message.contains("could not be re-scanned"))
    }

    // MARK: - Cancelled verify vs involuntary failure (issue #82)

    @Test func aCancelledVerifyIsNotVerifiedAndStatesBothFacts() {
        // A user cancel during verify: the file is saved AND the check was cancelled — both
        // facts stated plainly, and the outcome is its own case, not a discard.
        let v = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: false, cancelled: true, survivingZones: [])
        #expect(v.outcome == .notVerified)
        #expect(!v.clean)
        #expect(v.message.contains("saved the file"))
        #expect(v.message.contains("cancelled"))
    }

    @Test func aCancelledVerifyIsDistinctFromAnInvoluntaryReScanFailure() {
        // The whole point of #82: a user cancel (`.notVerified`) must not be confused with an
        // involuntary re-scan failure (`.inconclusive`) — different outcome, different wording.
        let cancelled = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: false, cancelled: true, survivingZones: [])
        let failed = ClipDoctorEngine.makeVerdict(clipName: "race", scanned: false, cancelled: false, survivingZones: [])
        #expect(cancelled.outcome == .notVerified)
        #expect(failed.outcome == .inconclusive)
        #expect(cancelled.outcome != failed.outcome)
        #expect(cancelled.message != failed.message)
    }

    @Test func verifyOutputReportsACancelAsNotVerifiedNotInconclusive() async {
        // `verifyOutput`'s first statement is a cancellation check, so a task cancelled before
        // it is awaited resolves to the cancelled (not-verified) verdict without touching
        // ffprobe — a cancel must never escape as a thrown error (the file is already written).
        let task = Task { () -> ClipDoctorEngine.Verdict in
            await ClipDoctorEngine.verifyOutput(
                URL(fileURLWithPath: "/nonexistent/out.ts"), clipName: "race", expectedDuration: 10)
        }
        task.cancel()
        let verdict = await task.value
        #expect(verdict.outcome == .notVerified)
    }

    // MARK: - Non-AV stream notice (ADR-0021: video + audio only)

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

    // MARK: - Non-AV stream parsing

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

    // MARK: - Import-banner suggestion text (issue #55)

    @Test func bannerNamesTheClipAndZoneCount() {
        #expect(ClipDoctorEngine.suggestionBannerText(clipName: "1844", zoneCount: 1)
                == "“1844” has a damage zone. Clip Doctor can repair it.")
        #expect(ClipDoctorEngine.suggestionBannerText(clipName: "1844", zoneCount: 9)
                == "“1844” has 9 damage zones. Clip Doctor can repair it.")
    }

    // MARK: - Field-coded (PAFF) damage-to-EOF plan + encoder (issue #54)

    /// A 2495-frame index with keyframes every 12 frames (a closed-GOP stand-in), so the
    /// transform's keyframe snap is exercised against a known grid.
    private func keyframeGridIndex(count: Int = 2495, gop: Int = 12) -> FrameIndex {
        let pts = (0..<count).map { Double($0) * 0.04 }
        let flags = (0..<count).map { $0 % gop == 0 }
        return FrameIndex(pts: pts, keyframeFlags: flags)
    }

    /// A whole-file plan that copies the clean head, repairs around an interior zone, then
    /// copies the tail collapses to: copy head to the seam keyframe, one re-encode to EOF.
    /// The seam snaps back to the keyframe at/before the planner's leading-picture-adjusted
    /// first-repair start (746 → keyframe 744 on a 12-frame grid).
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
        #expect(plan[0].range == 0..<744)                     // snapped to the keyframe ≤ 746
        #expect(plan[1].kind == .reEncode)
        #expect(plan[1].range == 744..<2495)                  // one re-encode from the seam to EOF
        #expect(plan[1].outCutKeyframe == nil)
        #expect(plan[1].damage == zones)                      // carries every video zone
    }

    /// Several zones all fold into the single tail re-encode; only video-affecting zones
    /// are carried, and the seam is the keyframe before the first repair.
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
        #expect(plan[1].damage == [z1, z2])                   // audio-only zone dropped
    }

    /// Damage before the first keyframe leaves no head copy — the repair is a single full
    /// re-encode (correct, just no longer minimal).
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

    /// The field-coded specialization pairs the damage-to-EOF plan with the MBAFF tail
    /// encoder atomically (issue #58): the plan is the `damageToEOFPlan` collapse and the
    /// encoder is `mbaffRepairVideoArgs`, so a caller can't mismatch a damage-to-EOF plan
    /// with the source-matched progressive args.
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

    /// `repair`'s planning flow end-to-end for a damaged field-coded clip (the #96
    /// regression pin): the whole-file `videoTreatment` with the `.repair` purpose still
    /// yields the interleaved copy/repair segments — the copy-only invariant is an
    /// `.export`-purpose rule and must not throw here — and `fieldCodedRepair` collapses
    /// them to the copy-head + re-encode-to-EOF shape (issue #54, ADR-0022).
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
        #expect(plan[1].range.upperBound == index.count)   // the tail runs to EOF
        #expect(plan[1].damage == [zone])
        #expect(encoder == BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: "tt"))
    }

    // MARK: - H.264-only field-coded guard (issue #57)

    /// The damage-to-EOF tail is always MBAFF H.264, so only an H.264 field-coded source can
    /// be repaired without a mixed-codec concat; MPEG-2/HEVC/unknown are refused. (Progressive
    /// repair is same-codec and not gated by this.)
    @Test func fieldCodedRepairIsH264Only() {
        #expect(ClipDoctorEngine.canRepairFieldCoded(codec: "h264"))
        for other in ["hevc", "mpeg2video", "vc1", nil] {
            #expect(!ClipDoctorEngine.canRepairFieldCoded(codec: other))
        }
    }

    /// The refusal names H.264 and the source codec, and stays banned-word clean.
    @Test func unsupportedFieldCodedCodecMessageNamesH264() {
        let msg = ClipDoctorEngine.DoctorError.unsupportedFieldCodedCodec("hevc").errorDescription ?? ""
        #expect(msg.contains("H.264"))
        #expect(msg.contains("HEVC"))
        for banned in ["fix", "heal", "patch", "error concealment"] {
            #expect(!msg.lowercased().contains(banned))
        }
    }

    // MARK: - Field order detection (issue #60)

    /// Only ffprobe's four interlaced labels are trusted without measuring; anything else
    /// (missing, unknown, progressive, garbage) must be measured with idet.
    @Test func definiteFieldOrderIsOnlyTheFourInterlacedLabels() {
        for ok in ["tt", "tb", "bb", "bt"] {
            #expect(ClipDoctorEngine.isDefiniteFieldOrder(ok))
        }
        for notOk in [nil, "", "unknown", "progressive", "TT", "interlaced"] {
            #expect(!ClipDoctorEngine.isDefiniteFieldOrder(notOk))
        }
    }

    /// The idet pass logs at info level (its summary is suppressed at -v error, de-risked),
    /// runs the interlace detector over a bounded frame budget, and decodes to the null muxer.
    @Test func fieldOrderDetectionArgsRunIdetAtInfoLevelWithAFrameBudget() {
        let args = ClipDoctorEngine.fieldOrderDetectionArguments(source: URL(fileURLWithPath: "/x/y.ts"), frames: 500)
        #expect(args[args.firstIndex(of: "-v")! + 1] == "info")
        #expect(args[args.firstIndex(of: "-vf")! + 1] == "idet")
        #expect(args[args.firstIndex(of: "-frames:v")! + 1] == "500")
        #expect(args.suffix(2) == ["-f", "null"] || args.contains("null"))
        #expect(args.contains("-an"))
    }

    /// Parses the cumulative "Multi frame detection" line — and takes the *last* one when idet
    /// printed running subtotals (the real capture's exact summary block).
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

    /// A dominant polarity over a mostly-interlaced sample decides; a split tally, a
    /// mostly-progressive sample, or too few frames is inconclusive (refuse, don't guess).
    @Test func fieldOrderFromIdetDecidesOnlyOnAClearDominantPolarity() {
        // The real capture: unanimous TFF.
        #expect(ClipDoctorEngine.fieldOrderFromIdet(.init(tff: 501, bff: 0, progressive: 0, undetermined: 0)) == "tt")
        // A clear BFF source.
        #expect(ClipDoctorEngine.fieldOrderFromIdet(.init(tff: 2, bff: 480, progressive: 5, undetermined: 3)) == "bb")
        // Split between polarities → inconclusive.
        #expect(ClipDoctorEngine.fieldOrderFromIdet(.init(tff: 260, bff: 240, progressive: 0, undetermined: 0)) == nil)
        // Mostly progressive (contradicts field-coded) → inconclusive.
        #expect(ClipDoctorEngine.fieldOrderFromIdet(.init(tff: 40, bff: 10, progressive: 400, undetermined: 50)) == nil)
        // Too few frames decoded → inconclusive.
        #expect(ClipDoctorEngine.fieldOrderFromIdet(.init(tff: 30, bff: 0, progressive: 0, undetermined: 0)) == nil)
    }

    /// The field-coded re-encode notice states full re-encode + not bit-identical, scales
    /// its estimate off the clip duration, and stays banned-word clean.
    @Test func fieldCodedNoticeWarnsFullReencodeAndScalesTheEstimate() {
        // A 4.8 h capture: ~1 h typical, up to ~5 h worst (the measured band).
        let long = ClipDoctorEngine.fieldCodedReencodeNotice(clipName: "1842", duration: 17_280)
        #expect(long.contains("not bit-for-bit identical"))
        #expect(long.contains("an hour"))
        #expect(long.contains("5 hours"))
        // No banned repair words.
        for banned in ["fix", "heal", "patch", "error concealment"] {
            #expect(!long.lowercased().contains(banned))
        }
        // Short clip rounds to a small phrase; missing duration omits the estimate.
        #expect(ClipDoctorEngine.fieldCodedReencodeNotice(clipName: "x", duration: 100)
            .contains("a minute or two"))
        #expect(!ClipDoctorEngine.fieldCodedReencodeNotice(clipName: "x", duration: nil)
            .contains("Expect"))
    }
}
