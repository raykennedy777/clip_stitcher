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

    @Test func mpeg2IntoMkvGetsThePtsRefillFilter() {
        // Matroska refuses the BBC capture's no-PTS packets on stream copy (issue #2);
        // the setts filter refills exactly those from DTS — same rule as the frame index.
        let bsf = ExportEngine.ptsRefillBitstreamFilter(codec: "mpeg2video", ext: "mkv")
        #expect(bsf == ["-bsf:v", "setts=pts=if(eq(PTS\\,NOPTS)\\,DTS\\,PTS)"])
    }

    /// A damaged source carries no-PTS packets whatever its codec (the 1844 capture's
    /// truncated pictures killed every MKV copy cut — even ones whose kept window was
    /// clean, since the segment muxer writes the discarded segments too). The refill
    /// extends to damaged clips into MKV; clean clips keep today's exact commands.
    @Test func damagedSourcesIntoMkvGetThePtsRefillWhateverTheCodec() {
        let want = ["-bsf:v", "setts=pts=if(eq(PTS\\,NOPTS)\\,DTS\\,PTS)"]
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "h264", ext: "mkv", damaged: true) == want)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "hevc", ext: "mkv", damaged: true) == want)
        // mp4/ts tolerate a missing PTS — no shape change there even when damaged.
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "h264", ext: "mp4", damaged: true).isEmpty)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "h264", ext: "ts", damaged: true).isEmpty)
    }

    @Test func everyOtherCodecContainerComboKeepsItsValidatedCommandShape() {
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "mpeg2video", ext: "ts").isEmpty)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "mpeg2video", ext: "mp4").isEmpty)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "h264", ext: "mkv").isEmpty)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: "hevc", ext: "mkv").isEmpty)
        #expect(ExportEngine.ptsRefillBitstreamFilter(codec: nil, ext: "mkv").isEmpty)
        // and without a filter the cut/remux commands are byte-identical to before
        let plan = SegmentPlan(inFrame: 10, outFrame: 20, inSegmentTime: 1.0, outSegmentTime: 2.0)
        let cut = ExportEngine.cutArguments(source: src, plan: plan, segmentPattern: "/tmp/p_%03d.ts")
        #expect(!cut.contains("-bsf:v"))
        let remux = ExportEngine.remuxArguments(source: src, output: URL(fileURLWithPath: "/tmp/o.ts"))
        #expect(!remux.contains("-bsf:v"))
    }

    // MARK: export-wide MP4 timescale (issue #24)

    @Test func exportWideTimescaleIsTheLcmOfTheProbes() {
        // the two real failure legs: 25000 vs 90000 sources, and an MKV-source 16000
        #expect(ExportEngine.exportWideTimescale(probed: [25000, 90000]) == 450000)
        #expect(ExportEngine.exportWideTimescale(probed: [16000, 25000]) == 400000)
        #expect(ExportEngine.exportWideTimescale(probed: [16000]) == 16000)
        #expect(ExportEngine.exportWideTimescale(probed: [25000, 25000]) == 25000)
    }

    @Test func exportWideTimescaleRefusesToOverflowTheMuxerRange() {
        // co-prime monsters would blow past Int32 — no pin beats a rounded pin
        #expect(ExportEngine.exportWideTimescale(probed: [1_000_003, 999_999_937]) == nil)
        #expect(ExportEngine.exportWideTimescale(probed: []) == nil)
    }

    @Test func copyCommandsCarryTheExportWideTimescale() {
        let plan = SegmentPlan(inFrame: 0, outFrame: 10, inSegmentTime: nil, outSegmentTime: 2.0)
        let cut = ExportEngine.cutArguments(source: src, plan: plan,
                                            segmentPattern: "/tmp/p_%03d.mp4", trackTimescale: 450000)
        // the segment muxer forwards inner-muxer flags only via -segment_format_options
        let i = cut.firstIndex(of: "-segment_format_options")
        #expect(i != nil && cut[cut.index(after: i!)] == "video_track_timescale=450000")
        let remux = ExportEngine.remuxArguments(source: src, output: URL(fileURLWithPath: "/tmp/o.mp4"),
                                                trackTimescale: 450000)
        let j = remux.firstIndex(of: "-video_track_timescale")
        #expect(j != nil && remux[remux.index(after: j!)] == "450000")
        // and without a pin both commands keep their validated shapes
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

    // MARK: - Audio re-encode

    @Test func audioInputArgsSeekAndLimitToTheClipRange() {
        // both ends cut: fast seek to start, read (end - start) seconds. Every audio
        // input tolerates decode errors (issue #44 — the default ⅔ threshold aborted
        // the run with a truncated output on the real capture's MP2 dead zone).
        let a = ExportEngine.audioInputArgs(source: src, start: 1654.8, end: 1727.6)
        #expect(a == ["-max_error_rate", "1.0", "-ss", "1654.8", "-t", "72.8", "-i", "/tmp/clip.mp4"])
    }

    @Test func audioInputArgsOmitSeekForAnOpenStart() {
        // no head cut: read from the file start up to `end`.
        let a = ExportEngine.audioInputArgs(source: src, start: nil, end: 30.0)
        #expect(a == ["-max_error_rate", "1.0", "-t", "30", "-i", "/tmp/clip.mp4"])
    }

    @Test func audioInputArgsOmitDurationForAnOpenEnd() {
        // no tail cut: seek to start, read to the file end.
        let a = ExportEngine.audioInputArgs(source: src, start: 10.0, end: nil)
        #expect(a == ["-max_error_rate", "1.0", "-ss", "10", "-i", "/tmp/clip.mp4"])
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
        // the track's format with the defensive gap-fill resample (issue #44) and forced
        // to its exact kept length (1 s / 2 s at 48 kHz — ADR-0014), then concatenated.
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc == "[1:a:0]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo,atrim=end_sample=48000,apad=whole_len=48000[c0t0];"
                    + "[2:a:0]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo,atrim=end_sample=96000,apad=whole_len=96000[c1t0];"
                    + "[c0t0][c1t0]concat=n=2:v=0:a=1[a0]")
        #expect(args.contains("[a0]"))
        #expect(args.last == "/tmp/out.ts")
    }

    @Test func audioMuxInsertsTheLegsMixBeforeItsConform() {
        // Clip 0 mixes track 0 to left-only (ADR-0019); clip 1 keeps Original. The pan
        // sits before the conform and wholly before the sample-exact atrim/apad, and
        // only on clip 0's leg — the join's sample math is untouched (shell-verified).
        var mixed = ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 1)
        mixed.audioMixFilters = ["pan=stereo|c0=c0|c1=c0"]
        let items = [mixed, ExportItem(source: src, codec: "h264", audioStart: 0, audioEnd: 1)]
        let args = ExportEngine.audioMuxArguments(videoInput: nil, items: items, tracks: [stereoTrack],
                                                  audioCodec: "aac", output: URL(fileURLWithPath: "/tmp/out.mkv"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc.contains("[0:a:0]pan=stereo|c0=c0|c1=c0,aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo,"
                          + "atrim=end_sample=48000,apad=whole_len=48000[c0t0]"))
        #expect(fc.contains("[1:a:0]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo,"
                          + "atrim=end_sample=48000,apad=whole_len=48000[c1t0]"))
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
        #expect(fc.contains("[2:a:0]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=mono,atrim=end_sample=96000,apad=whole_len=96000[c1t1]")
                == false) // the second clip has no second source…
        #expect(fc.contains("anullsrc=r=48000:cl=mono,atrim=end_sample=96000[c1t1]")) // …so it is silence
        // generated silence has no gaps to fill — the defensive resample stays off it
        #expect(!fc.contains("anullsrc=r=48000:cl=mono,aresample"))
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
        #expect(fc.contains("[2:a:1]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo,atrim=end_sample=96000,apad=whole_len=96000[c0t1]"))
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

    // MARK: plan-aware gate (issue #19): copy spans verify against the source's pattern

    /// 25fps source with the BBC capture's signature anomaly: a duplicated PTS at
    /// frame `dupAt`, then a double-slot gap two frames later that re-syncs.
    private func dirtySource(count: Int, dupAt: Int) -> [Double] {
        var pts: [Double] = []
        var t = 0.0
        for i in 0..<count {
            pts.append(t)
            // the duplicate's slot is repaid by the gap, so the tail re-syncs
            if i == dupAt { continue }              // duplicate: next frame shares t
            t += (i == dupAt + 2) ? 0.08 : 0.04     // gap two frames later
        }
        return pts
    }

    @Test func aFaithfulCopyOfAnIrregularSourcePasses() {
        let src = dirtySource(count: 120, dupAt: 50)
        let plan = [PlannedSegment(kind: .copy, range: 0..<100),
                    PlannedSegment(kind: .reEncode, range: 100..<110)]
        // piece = source pattern over the copy span + uniform re-encode tail
        var pts = Array(src[0..<100])
        let tail0 = src[99] + 0.04
        pts += (0..<10).map { tail0 + 0.04 * Double($0) }
        #expect(ExportEngine.timestampDefect(pts: pts) != nil)              // old gate rejected it
        #expect(ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src) == nil)
    }

    @Test func theReMaterializedAnomalyMayDriftUpToThreeIntervals() {
        // The mpegts round-trip refills the duplicate's lost pts from dts, displacing
        // the anomaly by up to the B-frame reorder depth (measured 2 on the real
        // BBC fixture; ±3 is the documented bound).
        let src = dirtySource(count: 120, dupAt: 50)
        let plan = [PlannedSegment(kind: .copy, range: 0..<100),
                    PlannedSegment(kind: .reEncode, range: 100..<110)]
        var drifted = dirtySource(count: 120, dupAt: 53)   // same shape, 3 intervals later
        drifted = Array(drifted[0..<100]) + (0..<10).map { drifted[99] + 0.04 * Double($0 + 1) }
        #expect(ExportEngine.timestampDefect(pts: drifted, plan: plan, sourcePts: src) == nil)
        var tooFar = dirtySource(count: 120, dupAt: 56)    // 6 intervals: not the same anomaly
        tooFar = Array(tooFar[0..<100]) + (0..<10).map { tooFar[99] + 0.04 * Double($0 + 1) }
        #expect(ExportEngine.timestampDefect(pts: tooFar, plan: plan, sourcePts: src) != nil)
    }

    /// The piece's outermost edges are not seams — nothing abuts them. A copy running
    /// to the file end may faithfully reproduce a source anomaly in its last intervals
    /// (the HEVC fixture's tail presents with a missing slot: a `-t` stream-copy keeps
    /// a decode-order prefix of its B-pyramid), and the source-match requirement still
    /// applies. Interior seams keep the strict window — that is where the shipped
    /// defect classes live.
    @Test func outerEdgesOfThePieceAreNotSeams() {
        // Source whose final interval is a double slot (B-pyramid tail cut).
        var src = (0..<100).map { 0.04 * Double($0) }
        src[99] = src[98] + 0.08
        let plan = [PlannedSegment(kind: .copy, range: 0..<100)]
        #expect(ExportEngine.timestampDefect(pts: src, plan: plan, sourcePts: src) == nil)
        // The same gap WITHOUT a source match still fails, outer edge or not.
        let clean = (0..<100).map { 0.04 * Double($0) }
        #expect(ExportEngine.timestampDefect(pts: src, plan: plan, sourcePts: clean) != nil)
        // An interior seam keeps the strict window: the same anomaly at a copy
        // segment's last interval before a re-encode segment is never excused.
        let interior = [PlannedSegment(kind: .copy, range: 0..<50),
                        PlannedSegment(kind: .reEncode, range: 50..<100)]
        var seamed = (0..<100).map { 0.04 * Double($0) }
        seamed[49] = seamed[48] + 0.08
        // ...even with an identical source — the seam stays strict.
        #expect(ExportEngine.timestampDefect(pts: seamed, plan: interior, sourcePts: seamed) != nil)
    }

    /// A repaired segment's output count differs from its frame range (holes filled,
    /// corrupt dropped — issue #47), shifting where later copy segments land in the
    /// piece. `outputCounts` re-anchors the mapping so a copy span after a repair still
    /// verifies against the source's own pattern at the right position.
    @Test func outputCountsReanchorCopySpansAfterARepairedSegment() {
        let src = dirtySource(count: 30, dupAt: 15)
        let z = DamageZone(start: 0.1, end: 0.2, affectsVideo: true)
        let plan = [PlannedSegment(kind: .reEncode, range: 0..<10, damage: [z]),
                    PlannedSegment(kind: .copy, range: 10..<25)]
        // The repaired piece came out 8 frames; the copy follows with the source's
        // dup at source frame 15 → output interval 8 + (15 − 10) = 13.
        var pts = (0..<8).map { 0.04 * Double($0) }
        var t = pts.last! + 0.04
        for i in 10..<25 {
            pts.append(t)
            if i == 15 { continue }
            t += (i == 17) ? 0.08 : 0.04
        }
        // Without the counts the plan can't map (23 ≠ 25 frames) → strict gate trips.
        #expect(ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src) != nil)
        #expect(ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src,
                                             outputCounts: [8, 15]) == nil)
    }

    @Test func anAnomalyTheSourceDoesNotHaveStillFails() {
        let src = (0..<120).map { 0.04 * Double($0) }      // clean source
        let plan = [PlannedSegment(kind: .copy, range: 0..<100),
                    PlannedSegment(kind: .reEncode, range: 100..<110)]
        var pts = (0..<110).map { 0.04 * Double($0) }
        pts[50] = pts[49]                                   // collapse inside the copy span
        let reason = ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src)
        #expect(reason?.contains("duplicate") == true)
    }

    @Test func aMatchingKindIsRequiredNotJustAnyAnomaly() {
        let src = dirtySource(count: 120, dupAt: 50)       // source has dup@50, gap@52
        let plan = [PlannedSegment(kind: .copy, range: 0..<100)]
        var pts = Array(src[0..<100])
        pts[20] = pts[19]                                   // dup where source is clean
        #expect(ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src) != nil)
    }

    @Test func seamAndSegmentEdgeWindowsStayStrict() {
        let plan = [PlannedSegment(kind: .copy, range: 0..<100),
                    PlannedSegment(kind: .reEncode, range: 100..<110)]
        // A source anomaly *at* the planned seam is not forgiven — the seam is where
        // the shipped defect classes live, so the gate stays conservative there (the
        // de-risk caught a real misplaced-seam gap exactly at this position).
        var src = (0..<120).map { 0.04 * Double($0) }
        for j in 100..<120 { src[j] += 0.04 }            // source gap at interval 99: the seam
        var pts = Array(src[0..<100])
        pts += (0..<10).map { src[100] + 0.04 * Double($0) }   // reproduces the seam gap
        let reason = ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src)
        #expect(reason?.contains("gap") == true)
        // an injected gap at the copy→re-encode seam of an otherwise clean export
        var clean = (0..<110).map { 0.04 * Double($0) }
        for j in 100..<110 { clean[j] += 0.04 }
        #expect(ExportEngine.timestampDefect(pts: clean, plan: plan,
                                             sourcePts: (0..<120).map { 0.04 * Double($0) }) != nil)
        // a source anomaly inside the 2-interval window at an *interior* copy edge is
        // also strict, even when the source matches — only the piece's outermost
        // edges relax (nothing abuts them; see outerEdgesOfThePieceAreNotSeams)
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
        pts[105] = pts[104]                                 // dup inside the re-encode
        let reason = ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: src)
        #expect(reason?.contains("duplicate") == true)
    }

    @Test func anEmptyPlanFallsBackToStrictUniformity() {
        let src = dirtySource(count: 120, dupAt: 50)
        let pts = Array(src[0..<100])
        #expect(ExportEngine.timestampDefect(pts: pts, plan: [], sourcePts: src) != nil)
    }
}

/// Pins the per-track own-codec mux shape (issue #31 / ADR-0018): cut-only tracks each
/// carry their own encoder via `-c:a:N` (de-risked in the shell on MPEG-2/H.264/HEVC in
/// TS/MKV/MP4); without per-track encoders the long-validated single `-c:a` shape is
/// emitted unchanged.
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

/// Pins the `.separate`-mode file naming contract (issue #30): `NN <clip name>.<ext>`
/// in timeline order, zero-padded to the clip total (minimum two digits), source
/// extension dropped, filesystem-hostile characters replaced, and a collision suffix
/// as a guard even though distinct prefixes should make collisions impossible.
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
