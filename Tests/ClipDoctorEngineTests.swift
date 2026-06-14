import Testing
import Foundation
@testable import VidConform

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

    // MARK: - Bounded keyframe copy

    /// 10 frames at 25 fps starting at the container's 1.0 s start_time.
    private var index: FrameIndex {
        let pts = (0..<10).map { 1.0 + Double($0) * 0.04 }
        return FrameIndex(pts: pts, keyframeFlags: Array(repeating: true, count: 10))
    }

    @Test func boundedCopySeeksToTheSpanAndSplitsAfterItsFrameCount() {
        let args = BoundaryReencodeEngine.boundedCopyArguments(
            source: src, range: 2..<6, index: index, containerStart: 1.0,
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
            source: src, range: 0..<4, index: index, containerStart: 1.0,
            segmentPattern: "/tmp/cp_%03d.ts")
        #expect(args[args.firstIndex(of: "-ss")! + 1] == "0")
        #expect(args[args.firstIndex(of: "-segment_frames")! + 1] == "4")
    }

    @Test func boundedCopyOfTheTailRunsToTheLastFrame() {
        // hi == count: span end is the last frame's pts, frame count is count − lo.
        let args = BoundaryReencodeEngine.boundedCopyArguments(
            source: src, range: 6..<10, index: index, containerStart: 1.0,
            segmentPattern: "/tmp/cp_%03d.ts")
        #expect(args[args.firstIndex(of: "-segment_frames")! + 1] == "4")
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
}
