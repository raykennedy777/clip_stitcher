import Testing
import Foundation
@testable import VidConform

/// Exercises the pure argument-building core of the Milestone 1 export engine — the
/// ffmpeg invocations that cut each clip's video at its clean cut points, concat the
/// pieces, and rebuild a continuous re-encoded audio track aligned to the video
/// (ADR-0008). These pin the command shape, which was validated against real footage.
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
        // video-only — audio is rebuilt separately, never copied by the cut
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
        #expect(!args.contains("-f"))           // no segment muxer
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

    @Test func mpeg2IsIncompatibleWithMkvButFineElsewhere() {
        // Matroska can't stream-copy MPEG-2 (unknown-timestamp at joins); TS/MP4 can.
        #expect(ExportEngine.streamCopyCompatible(codec: "mpeg2video", container: .mkv) == false)
        #expect(ExportEngine.streamCopyCompatible(codec: "mpeg2video", container: .ts) == true)
        #expect(ExportEngine.streamCopyCompatible(codec: "mpeg2video", container: .mp4) == true)
        // H.264/HEVC are fine in every container.
        #expect(ExportEngine.streamCopyCompatible(codec: "h264", container: .mkv) == true)
        #expect(ExportEngine.streamCopyCompatible(codec: "hevc", container: .mkv) == true)
    }

    // MARK: - Audio re-encode

    @Test func audioInputArgsSeekAndLimitToTheClipRange() {
        // both ends cut: fast seek to start, read (end - start) seconds.
        let a = ExportEngine.audioInputArgs(source: src, start: 1654.8, end: 1727.6)
        #expect(a == ["-ss", "1654.8", "-t", "72.8", "-i", "/tmp/clip.mp4"])
    }

    @Test func audioInputArgsOmitSeekForAnOpenStart() {
        // no head cut: read from the file start up to `end`.
        let a = ExportEngine.audioInputArgs(source: src, start: nil, end: 30.0)
        #expect(a == ["-t", "30", "-i", "/tmp/clip.mp4"])
    }

    @Test func audioInputArgsOmitDurationForAnOpenEnd() {
        // no tail cut: seek to start, read to the file end.
        let a = ExportEngine.audioInputArgs(source: src, start: 10.0, end: nil)
        #expect(a == ["-ss", "10", "-i", "/tmp/clip.mp4"])
    }

    @Test func audioMuxConcatenatesItemAudioOverCopiedVideo() {
        let video = URL(fileURLWithPath: "/tmp/joined.ts")
        let items = [
            ExportItem(source: src, codec: "mpeg2video", audioStart: 1.0, audioEnd: 2.0),
            ExportItem(source: src, codec: "mpeg2video", audioStart: 5.0, audioEnd: 7.0),
        ]
        let args = ExportEngine.audioMuxArguments(videoInput: video, items: items,
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.ts"))
        // video copied, audio re-encoded
        #expect(args.contains("0:v:0") && args.contains("-c:v") && args.contains("copy"))
        #expect(args.contains("-c:a") && args.contains("aac"))
        // two audio inputs (indices 1 and 2 after the video input), concatenated
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[1:a:0][2:a:0]concat=n=2:v=0:a=1[a]")
        #expect(args.last == "/tmp/out.ts")
    }

    @Test func audioMuxConformsAMismatchedLegBeforeConcat() {
        // A conforming clip's audio is resampled/remixed to the target before the concat, so
        // the sample-level concat stays valid; a matching leg is referenced directly. The
        // all-matching command shape (above) is unchanged when no leg conforms.
        let video = URL(fileURLWithPath: "/tmp/joined.ts")
        let items = [
            ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 2),
            ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 2,
                       audioConform: ExportEngine.AudioConform(sampleRate: 48000, channels: 2)),
        ]
        let args = ExportEngine.audioMuxArguments(videoInput: video, items: items,
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.ts"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[2:a:0]aresample=48000,aformat=channel_layouts=stereo[ca1];"
                    + "[1:a:0][ca1]concat=n=2:v=0:a=1[a]")
    }

    @Test func audioMuxWithoutVideoStartsAudioInputsAtZero() {
        // audio-only export: no video input, so the first audio source is input 0.
        let items = [ExportItem(source: src, codec: "mpeg2video", audioStart: 1.0, audioEnd: 2.0)]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items,
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/a.m4a"))
        #expect(!args.contains("0:v:0"))
        #expect(!args.contains("-c:v"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[0:a:0]concat=n=1:v=0:a=1[a]")
    }

    @Test func audioMuxEncodesToTheGivenCodec() {
        let items = [ExportItem(source: src, codec: "mpeg2video", audioStart: 1.0, audioEnd: 2.0)]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items,
                                                  audioCodec: "mp2", output: URL(fileURLWithPath: "/tmp/a.ts"))
        let ca = args[args.firstIndex(of: "-c:a")! + 1]
        #expect(ca == "mp2")
    }

    // MARK: audio codec resolution (ADR-0010)

    @Test func resolvesToTargetCodecWhenContainerAllowsIt() {
        // mp2 source -> TS: keep mp2, map to its encoder, no fallback warning.
        let choice = ExportEngine.resolveAudioCodec(targetCodec: "mp2", container: .ts)
        #expect(choice == ExportEngine.AudioEncodeChoice(codec: "mp2", encoder: "mp2", fellBack: false))
        // mp3 maps to libmp3lame.
        #expect(ExportEngine.resolveAudioCodec(targetCodec: "mp3", container: .mkv).encoder == "libmp3lame")
    }

    @Test func fallsBackToAACForMp2InMp4() {
        // The one awkward combo: mp2 can't sit cleanly in MP4, so fall back + flag a warning.
        let choice = ExportEngine.resolveAudioCodec(targetCodec: "mp2", container: .mp4)
        #expect(choice == ExportEngine.AudioEncodeChoice(codec: "aac", encoder: "aac", fellBack: true))
    }

    @Test func fallsBackToAACForAnUnmappableCodec() {
        let choice = ExportEngine.resolveAudioCodec(targetCodec: "dts", container: .mkv)
        #expect(choice.encoder == "aac" && choice.fellBack)
    }

    @Test func anAACTargetUsesAACWithoutFlaggingAFallback() {
        // No codec was declined, so no warning.
        #expect(ExportEngine.resolveAudioCodec(targetCodec: "aac", container: .mp4)
                == ExportEngine.AudioEncodeChoice(codec: "aac", encoder: "aac", fellBack: false))
    }

    @Test func noTargetAudioDefaultsToAACWithoutAWarning() {
        #expect(ExportEngine.resolveAudioCodec(targetCodec: nil, container: .ts)
                == ExportEngine.AudioEncodeChoice(codec: "aac", encoder: "aac", fellBack: false))
    }

    // MARK: audio-only output (#1)

    @Test func audioOnlyKeepsTheTargetCodecRegardlessOfContainer() {
        // No video container to fit — mp2 stays mp2 even though it wouldn't fit MP4 video.
        #expect(ExportEngine.resolveAudioOnlyCodec(targetCodec: "mp2")
                == ExportEngine.AudioEncodeChoice(codec: "mp2", encoder: "mp2", fellBack: false))
        // An unmappable codec still falls back to AAC and flags it.
        let dts = ExportEngine.resolveAudioOnlyCodec(targetCodec: "dts")
        #expect(dts.encoder == "aac" && dts.fellBack)
        // No target audio -> AAC, no warning.
        #expect(ExportEngine.resolveAudioOnlyCodec(targetCodec: nil)
                == ExportEngine.AudioEncodeChoice(codec: "aac", encoder: "aac", fellBack: false))
    }

    @Test func audioOnlyExtensionFollowsTheEncoder() {
        #expect(ExportEngine.audioFileExtension(forEncoder: "aac") == "m4a")
        #expect(ExportEngine.audioFileExtension(forEncoder: "mp2") == "mp2")
        #expect(ExportEngine.audioFileExtension(forEncoder: "ac3") == "ac3")
        #expect(ExportEngine.audioFileExtension(forEncoder: "libmp3lame") == "mp3")
    }

    @Test func outputExtensionUsesAudioExtForAudioOnlyElseContainer() {
        // audio-only ignores the video container and follows the codec.
        #expect(ExportEngine.outputExtension(type: .audioOnly, container: .mp4, audioEncoder: "mp2") == "mp2")
        // video outputs keep the container extension.
        #expect(ExportEngine.outputExtension(type: .videoAndAudio, container: .ts, audioEncoder: "mp2") == "ts")
        #expect(ExportEngine.outputExtension(type: .videoOnly, container: .mkv, audioEncoder: "aac") == "mkv")
    }
}
