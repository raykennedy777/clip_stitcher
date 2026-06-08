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
                                                  output: URL(fileURLWithPath: "/tmp/out.ts"))
        // video copied, audio re-encoded
        #expect(args.contains("0:v:0") && args.contains("-c:v") && args.contains("copy"))
        #expect(args.contains("-c:a") && args.contains("aac"))
        // two audio inputs (indices 1 and 2 after the video input), concatenated
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[1:a:0][2:a:0]concat=n=2:v=0:a=1[a]")
        #expect(args.last == "/tmp/out.ts")
    }

    @Test func audioMuxWithoutVideoStartsAudioInputsAtZero() {
        // audio-only export: no video input, so the first audio source is input 0.
        let items = [ExportItem(source: src, codec: "mpeg2video", audioStart: 1.0, audioEnd: 2.0)]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items,
                                                  output: URL(fileURLWithPath: "/tmp/a.m4a"))
        #expect(!args.contains("0:v:0"))
        #expect(!args.contains("-c:v"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[0:a:0]concat=n=1:v=0:a=1[a]")
    }
}
