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

    // MARK: - Kept window (issue #3: input -ss is measured from the container's
    // start_time, not absolute pts — ADR-0015)

    @Test func keptWindowSubtractsTheContainerStartFromTheSeek() {
        // The measured .mpg case: in point at pts 60.2 in a 0.24-start container must
        // seek 59.96 — passing 60.2 lands 0.24 s late in content (measured +230 ms
        // audio-ahead lip-sync error in the real TS output).
        let w = ExportEngine.keptWindow(inPts: 60.2, outPts: 70.2, firstPts: 0.24,
                                        lastPts: 4020.2, frameDuration: 0.04, containerStart: 0.24)
        #expect(w.start == 59.96)
        #expect(abs(w.end! - 69.96) < 1e-9)
        #expect(w.duration == 10.0)
    }

    @Test func keptWindowIsUnchangedOnAZeroStartContainer() {
        let w = ExportEngine.keptWindow(inPts: 57.0, outPts: 60.0, firstPts: 0.04,
                                        lastPts: 5169.0, frameDuration: 0.04, containerStart: 0)
        #expect(w.start == 57.0)
        #expect(w.end == 60.0)
        #expect(w.duration == 3.0)
    }

    @Test func keptWindowOpenStartReadsFromTheFileStart() {
        // No in point: no seek at all (and none needed — reading from the start is
        // immune to the start_time trap). Duration spans first frame to the out pts.
        let w = ExportEngine.keptWindow(inPts: nil, outPts: 10.24, firstPts: 0.24,
                                        lastPts: 4020.2, frameDuration: 0.04, containerStart: 0.24)
        #expect(w.start == nil)
        #expect(w.end == 10.0)
        #expect(w.duration == 10.0)
    }

    @Test func keptWindowOpenEndRunsToTheLastFrame() {
        // No out point: read to the file end; the kept span ends one frame *after*
        // the last frame's pts (the last frame still displays for a frame).
        let w = ExportEngine.keptWindow(inPts: 4010.2, outPts: nil, firstPts: 0.24,
                                        lastPts: 4020.2, frameDuration: 0.04, containerStart: 0.24)
        #expect(w.start == 4009.96)
        #expect(w.end == nil)
        #expect(abs(w.duration - 10.04) < 1e-9)
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
        // video copied, audio re-encoded
        #expect(args.contains("0:v:0") && args.contains("-c:v") && args.contains("copy"))
        #expect(args.contains("-c:a") && args.contains("aac"))
        // two audio inputs (indices 1 and 2 after the video input), each leg conformed to
        // the track's format and forced to its exact kept length (1 s / 2 s at 48 kHz —
        // ADR-0014), then concatenated.
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[1:a:0]aresample=48000,aformat=channel_layouts=stereo,atrim=end_sample=48000,apad=whole_len=48000[c0t0];"
                    + "[2:a:0]aresample=48000,aformat=channel_layouts=stereo,atrim=end_sample=96000,apad=whole_len=96000[c1t0];"
                    + "[c0t0][c1t0]concat=n=2:v=0:a=1[a0]")
        #expect(args.contains("[a0]"))
        #expect(args.last == "/tmp/out.ts")
    }

    @Test func audioMuxSilenceFillsAClipWithoutTheTrack(){
        // Two output tracks, but the second clip only carries one source: its leg on
        // track 2 is anullsrc silence in the track's format, trimmed to the same exact
        // sample count as its real legs (ADR-0014).
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
        #expect(fc.contains("[2:a:0]aresample=48000,aformat=channel_layouts=mono,atrim=end_sample=96000,apad=whole_len=96000[c1t1]")
                == false) // the second clip has no second source…
        #expect(fc.contains("anullsrc=r=48000:cl=mono,atrim=end_sample=96000[c1t1]")) // …so it is silence
        #expect(fc.contains("[c0t0][c1t0]concat=n=2:v=0:a=1[a0]"))
        #expect(fc.contains("[c0t1][c1t1]concat=n=2:v=0:a=1[a1]"))
        // both rebuilt tracks mapped
        #expect(args.contains("[a0]") && args.contains("[a1]"))
    }

    @Test func audioMuxReadsAnExternalFileAsItsOwnInput() {
        // A track re-pointed at an external file: the file gets its own input with the
        // SAME seek window as the clip (file start = video start — ADR-0014) and feeds
        // the leg via the chosen audio stream of that file.
        let external = URL(fileURLWithPath: "/tmp/demo.mkv")
        let items = [ExportItem(source: src, codec: "h264", audioStart: 10.0, audioEnd: 12.0,
                                audioSources: [.stream(0), .external(external, stream: 1)])]
        let args = ExportEngine.audioMuxArguments(videoInput: URL(fileURLWithPath: "/tmp/joined.mp4"),
                                                  items: items, tracks: [stereoTrack, stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.mp4"))
        // inputs: 0 video, 1 the clip, 2 the external file — both with -ss 10 -t 2
        #expect(args.contains("/tmp/demo.mkv"))
        #expect(args.filter { $0 == "10" }.count == 2 && args.filter { $0 == "2" }.count == 2)
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc.contains("[2:a:1]aresample=48000,aformat=channel_layouts=stereo,atrim=end_sample=96000,apad=whole_len=96000[c0t1]"))
    }

    @Test func audioMuxSharesOneInputAcrossTwoStreamsOfTheSameExternalFile() {
        // Two slots fed by different streams of the same external file: one -i for the
        // file, two leg references into it.
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
        // The app passes the kept *video* span explicitly; the window fallback only
        // covers builder calls without it.
        let items = [ExportItem(source: src, codec: "h264", audioStart: 1.0, audioEnd: 2.0,
                                audioSources: [.stream(0)], audioDuration: 1.5)]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items, tracks: [stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/a.m4a"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc.contains("atrim=end_sample=72000,apad=whole_len=72000"))
    }

    @Test func audioMuxWithoutVideoStartsAudioInputsAtZero() {
        // audio-only export: no video input, so the first audio source is input 0.
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

    // MARK: concat duration directives (the start_time seam gap, ADR-0008)

    @Test func concatListOmitsDurationsByDefault() {
        // The bare two-arg call must reproduce the plain list (no `duration` lines).
        let pieces = [URL(fileURLWithPath: "/tmp/a.mkv"), URL(fileURLWithPath: "/tmp/b.mkv")]
        let list = ExportEngine.concatListContents(pieces: pieces)
        #expect(!list.contains("duration"))
        #expect(list == "file '/tmp/a.mkv'\nfile '/tmp/b.mkv'\n")
    }

    @Test func concatListEmitsDurationDirectivesAlignedToPieces() {
        // A head-copy span of 3.56s pins the demuxer's advance so the re-encode piece can't
        // land late; a `nil` (the final, run-to-end piece) emits no directive.
        let pieces = [URL(fileURLWithPath: "/tmp/cp.mkv"), URL(fileURLWithPath: "/tmp/re.mkv")]
        let list = ExportEngine.concatListContents(pieces: pieces, durations: [3.56, nil])
        #expect(list == "file '/tmp/cp.mkv'\nduration 3.56\nfile '/tmp/re.mkv'\n")
    }

    @Test func concatListSkipsNonPositiveDurations() {
        let pieces = [URL(fileURLWithPath: "/tmp/a.mkv"), URL(fileURLWithPath: "/tmp/b.mkv")]
        let list = ExportEngine.concatListContents(pieces: pieces, durations: [0, nil])
        #expect(!list.contains("duration"))
    }

    // MARK: cross-clip spans (issue #6 — the same seam gap at the join between clips)

    /// The biting case: a single-copy-segment clip trimmed only at its tail (segment 0 of
    /// the muxer cut keeps the source's non-zero start_time). Its span is exact —
    /// `pts[hi] - pts[lo]` of the kept range — because `hi` is a real, in-bounds frame.
    @Test func clipSpanOfATrimmedSmartRenderedClipIsExact() {
        // A source at start_time 0.24, 25fps; kept [0, 4) — trimmed on a copy-safe keyframe.
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let item = ExportItem(source: URL(fileURLWithPath: "/tmp/a.mpg"),
                              segments: [PlannedSegment(kind: .copy, range: 0..<4)], index: index)
        #expect(abs((ExportEngine.clipSpan(item) ?? -1) - 0.16) < 1e-9)   // pts[4] - pts[0]
    }

    /// A clip kept to its end (`hi == count`, `pts[hi]` out of bounds) estimates the last
    /// frame's slot from the mean frame interval — safe because a clip is CFR.
    @Test func clipSpanOfARunToEndClipAddsOneFrameSlot() {
        let index = FrameIndex(
            pts: [0.24, 0.28, 0.32, 0.36, 0.40, 0.44, 0.48, 0.52],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let item = ExportItem(source: URL(fileURLWithPath: "/tmp/a.mpg"),
                              segments: [PlannedSegment(kind: .copy, range: 0..<4),
                                         PlannedSegment(kind: .reEncode, range: 4..<8)], index: index)
        // pts[7] - pts[0] + one 0.04 slot = the full 8-frame clip = 0.32.
        #expect(abs((ExportEngine.clipSpan(item) ?? -1) - 0.32) < 1e-9)
    }

    /// A conformed clip re-encodes its kept window to the target spec preserving duration,
    /// so its span is the kept duration the app supplies (closed-window fallback).
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

    /// The last clip offsets nothing → `nil`; an uncomputable span (no segments, no
    /// conform) degrades to `nil` — no directive, today's behavior — rather than a guess.
    @Test func clipSpansLastClipAndUncomputableSpansAreNil() {
        let index = FrameIndex(pts: [0.0, 0.04, 0.08, 0.12],
                               keyframeFlags: [true, false, false, false])
        let trimmed = ExportItem(source: URL(fileURLWithPath: "/tmp/a.mp4"),
                                 segments: [PlannedSegment(kind: .copy, range: 0..<2)], index: index)
        let planless = ExportItem(source: URL(fileURLWithPath: "/tmp/b.mp4"))
        let spans = ExportEngine.clipSpans(items: [trimmed, planless, trimmed])
        #expect(spans.count == 3)
        #expect(abs((spans[0] ?? -1) - 0.08) < 1e-9)
        #expect(spans[1] == nil)   // uncomputable → no directive
        #expect(spans[2] == nil)   // last clip → no directive
    }

    // MARK: timestamp self-check (catches both shipped defects)

    @Test func timestampDefectPassesUniformSpacing() {
        let pts = (0..<100).map { 0.04 * Double($0) }   // clean 25fps run
        #expect(ExportEngine.timestampDefect(pts: pts) == nil)
    }

    @Test func timestampDefectCatchesASeamGap() {
        // 25fps that skips one slot at frame 89 (the start_time off-by-one): …3.52, 3.60…
        var pts = (0..<89).map { 0.04 * Double($0) }
        pts += (89..<100).map { 0.04 * Double($0) + 0.04 }
        let reason = ExportEngine.timestampDefect(pts: pts)
        #expect(reason != nil)
        #expect(reason?.contains("gap") == true)
    }

    @Test func timestampDefectCatchesADuplicate() {
        // Two frames collapsed onto one PTS (the B-pyramid/MKV mux defect).
        var pts = (0..<50).map { 0.04 * Double($0) }
        pts[25] = pts[24]
        let reason = ExportEngine.timestampDefect(pts: pts)
        #expect(reason != nil)
        #expect(reason?.contains("duplicate") == true)
    }

    @Test func timestampDefectIgnoresTooFewFrames() {
        #expect(ExportEngine.timestampDefect(pts: [0.0, 0.04]) == nil)
    }
}
