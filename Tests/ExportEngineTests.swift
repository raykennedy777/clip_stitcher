import Testing
import Foundation
@testable import VidConform

/// Exercises the pure argument-building core of the Milestone 1 export engine — the
/// ffmpeg invocations that cut each clip at its clean cut points and concat the pieces
/// (ADR-0008). The cut times come straight from the plan (DTS-based); these tests pin
/// the command shape, which was validated against real footage in the shell.
struct ExportEngineTests {
    private let src = URL(fileURLWithPath: "/tmp/clip.mp4")

    @Test func wantedSegmentIsZeroWithoutAHeadCut() {
        // out-only (tail trimmed): the kept piece is the first segment.
        let plan = SegmentPlan(inFrame: 0, outFrame: 8, inMoved: false, outMoved: false,
                               inSegmentTime: nil, outSegmentTime: 0.30)
        #expect(ExportEngine.wantedSegmentIndex(plan: plan) == 0)
    }

    @Test func wantedSegmentIsOneAfterAHeadCut() {
        // in present (head trimmed): the kept piece is the segment after the first cut.
        let plan = SegmentPlan(inFrame: 2, outFrame: 8, inMoved: false, outMoved: false,
                               inSegmentTime: 0.06, outSegmentTime: 0.30)
        #expect(ExportEngine.wantedSegmentIndex(plan: plan) == 1)
    }

    @Test func cutArgumentsJoinBothCutTimesAndCopyVideoAndAudio() {
        let plan = SegmentPlan(inFrame: 2, outFrame: 8, inMoved: false, outMoved: false,
                               inSegmentTime: 0.06, outSegmentTime: 0.30)
        let args = ExportEngine.cutArguments(source: src, plan: plan, type: .videoAndAudio,
                                             segmentPattern: "/tmp/seg_%03d.mp4")
        #expect(args.contains("-c") && args.contains("copy"))
        #expect(args.contains("-segment_times"))
        // both times, ascending, comma-joined
        let times = args[args.firstIndex(of: "-segment_times")! + 1]
        #expect(times == "0.06,0.3")
        #expect(args.contains("0:v:0"))
        #expect(args.contains("0:a:0?"))
        #expect(args.last == "/tmp/seg_%03d.mp4")
    }

    @Test func aClipTrimmingNeitherEndNeedsNoCut() {
        // both boundaries nil = copy the whole clip; the segment muxer would split it at
        // every keyframe, so this takes the plain-remux path instead.
        let whole = SegmentPlan(inFrame: 0, outFrame: 9, inMoved: false, outMoved: false,
                                inSegmentTime: nil, outSegmentTime: nil)
        #expect(ExportEngine.needsCut(whole) == false)
        let trimmed = SegmentPlan(inFrame: 2, outFrame: 9, inMoved: false, outMoved: false,
                                  inSegmentTime: 0.06, outSegmentTime: nil)
        #expect(ExportEngine.needsCut(trimmed) == true)
    }

    @Test func remuxArgumentsCopyTheWholeClipToOneFile() {
        let out = URL(fileURLWithPath: "/tmp/clip0.mp4")
        let args = ExportEngine.remuxArguments(source: src, type: .videoAndAudio, output: out)
        #expect(!args.contains("-f"))           // no segment muxer
        #expect(args.contains("-c") && args.contains("copy"))
        #expect(args.contains("0:v:0") && args.contains("0:a:0?"))
        #expect(args.last == "/tmp/clip0.mp4")
    }

    @Test func videoOnlyMapsOnlyTheVideoStream() {
        let plan = SegmentPlan(inFrame: 2, outFrame: 8, inMoved: false, outMoved: false,
                               inSegmentTime: 0.06, outSegmentTime: 0.30)
        let args = ExportEngine.cutArguments(source: src, plan: plan, type: .videoOnly,
                                             segmentPattern: "/tmp/seg_%03d.mp4")
        #expect(args.contains("0:v:0"))
        #expect(!args.contains("0:a:0?"))
    }

    @Test func concatArgumentsUseTheConcatDemuxerWithCopy() {
        let list = URL(fileURLWithPath: "/tmp/list.txt")
        let out = URL(fileURLWithPath: "/tmp/out.mp4")
        let args = ExportEngine.concatArguments(listFile: list, output: out)
        #expect(args.contains("concat"))
        #expect(args.contains("-safe") && args.contains("0"))
        #expect(args.contains("-c") && args.contains("copy"))
        #expect(args.last == "/tmp/out.mp4")
    }

    /// The concat demuxer reads a list of `file '<path>'` lines; paths with quotes are
    /// escaped so a crafted filename can't break out of the directive.
    @Test func concatListEscapesSingleQuotesInPaths() {
        let pieces = [URL(fileURLWithPath: "/tmp/a's clip.mp4"), URL(fileURLWithPath: "/tmp/b.mp4")]
        let list = ExportEngine.concatListContents(pieces: pieces)
        #expect(list.contains("file '/tmp/a'\\''s clip.mp4'"))
        #expect(list.contains("file '/tmp/b.mp4'"))
    }
}
