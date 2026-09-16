import Testing
import Foundation
@testable import ClipStitcher

/// The plan query's report (issue #115): everything `clipstitch --plan` prints, derived
/// from a prepared job with no tool run at all. The inputs here are a synthetic frame
/// index and hand-built `ExportItem`s — the same shape `BoundaryReencodePlannerTests`
/// uses — so every number below is checkable by hand.
struct PlanReportTests {

    // MARK: - Synthetic job

    /// 60 frames at 25 fps, a keyframe every 10, no B-frames (dts = pts, so every
    /// keyframe is copy-safe).
    private static let index = FrameIndex(
        pts: (0..<60).map { Double($0) / 25 },
        keyframeFlags: (0..<60).map { $0 % 10 == 0 })

    private func video(codec: String = "h264", sar: String = "1:1") -> VideoProperties {
        VideoProperties(codec: codec, profile: "High", level: "41", width: 1920, height: 1080,
                        frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: "progressive",
                        sampleAspectRatio: sar, colorPrimaries: nil, colorTransfer: nil,
                        colorRange: nil)
    }

    private func clip(name: String, video: VideoProperties,
                      inPoint: Int? = nil, outPoint: Int? = nil,
                      audio: AudioProperties? = nil) -> Clip {
        var c = Clip(bookmark: Data(), displayName: name)
        c.video = video
        c.inPoint = inPoint
        c.outPoint = outPoint
        c.audio = audio
        c.audioTracks = audio.map { [$0] }
        return c
    }

    /// A two-clip job: a smart-rendered target cut at [5, 44] (neither mark on a
    /// keyframe, so both boundary GOPs re-encode) and a conformed fill whose pixel
    /// aspect ratio differs.
    private func prepared(target targetClip: Clip, targetItem: ExportItem,
                          fill fillClip: Clip, fillItem: ExportItem,
                          tracks: [AudioCodecPolicy.OutputAudioTrack],
                          warnings: [String] = []) -> StitchPipeline.Prepared {
        let job = StitchJob(version: 1, clips: [
            StitchJob.JobClip(path: "/media/target.mkv", target: true),
            StitchJob.JobClip(path: "/media/fill.mkv"),
        ])
        func facts(_ path: String, _ clip: Clip) -> StitchPipeline.SourceFacts {
            StitchPipeline.SourceFacts(
                url: URL(fileURLWithPath: path),
                probe: MediaProbe.Result(video: clip.video, audio: clip.audio,
                                         audioTracks: clip.allAudioTracks),
                index: Self.index, fieldCoded: false, damageZones: [])
        }
        return StitchPipeline.Prepared(
            job: job, settings: OutputSettings(),
            facts: ["/media/target.mkv": facts("/media/target.mkv", targetClip),
                    "/media/fill.mkv": facts("/media/fill.mkv", fillClip)],
            clips: [targetClip, fillClip], targetIndex: 0,
            items: [targetItem, fillItem],
            audio: AudioCodecPolicy.AudioEncodeChoice(codec: "ac3", encoder: "ac3", fellBack: false),
            tracks: tracks, warnings: warnings)
    }

    /// The canonical report: a target cut between keyframes, a fill that must conform.
    private func canonicalReport() -> PlanReport {
        let targetAudio = AudioProperties(codec: "ac3", sampleRate: 48000, channels: 2,
                                          channelLayout: "stereo", bitrate: 384_000)
        let targetClip = clip(name: "part 1", video: video(), inPoint: 5, outPoint: 44,
                              audio: targetAudio)
        let targetItem = ExportItem(
            source: URL(fileURLWithPath: "/media/target.mkv"), displayName: "part 1",
            codec: "h264",
            segments: [PlannedSegment(kind: .reEncode, range: 5..<10),
                       PlannedSegment(kind: .copy, range: 10..<40, outCutKeyframe: 40),
                       PlannedSegment(kind: .reEncode, range: 40..<45)],
            index: Self.index, frameRate: "25/1")
        let fillClip = clip(name: "Fill", video: video(sar: "64:45"), audio: targetAudio)
        let fillItem = ExportItem(
            source: URL(fileURLWithPath: "/media/fill.mkv"), displayName: "Fill",
            codec: "h264", audioStart: 0, audioEnd: 2.4,
            conform: ConformEngine.VideoConform(sourceVideo: video(sar: "64:45"),
                                                targetVideo: video()))
        return PlanReport.make(prepared: prepared(
            target: targetClip, targetItem: targetItem,
            fill: fillClip, fillItem: fillItem,
            tracks: [AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2)]))
    }

    // MARK: - Segments

    /// A cut between keyframes plans a re-encoded head, a copied middle and a re-encoded
    /// tail — reported as half-open frame ranges with their durations off the index pts.
    @Test func segmentsCarryHalfOpenRangesAndMeasuredSeconds() {
        let plan = canonicalReport().clips[0]
        #expect(plan.treatment == .smartRender)
        #expect(plan.segments?.map(\.kind) == [.reEncode, .copy, .reEncode])
        #expect(plan.segments?.map(\.frames) == [[5, 10], [10, 40], [40, 45]])
        #expect(plan.segments?.map(\.seconds) == [0.2, 1.2, 0.2])
        #expect(plan.reason == nil)
    }

    /// `PlannedSegment` records no reason, so the report reads it back off the segment's
    /// position: the head names the in point, the tail the out point, and a copy names
    /// nothing.
    @Test func reEncodeSegmentsExplainThemselvesFromTheirPosition() {
        let segments = canonicalReport().clips[0].segments ?? []
        #expect(segments[0].reason
                == "in point is not a copy-safe keyframe; nearest copy-safe keyframe at or after it is 10")
        #expect(segments[1].reason == nil)
        #expect(segments[2].reason
                == "out point is not a copy-safe keyframe; nearest copy-safe keyframe at or before it is 40")
    }

    /// Both mark conditions hold at once when the whole kept range is one re-encode, and
    /// every cause that applies is named.
    @Test func aSingleReEncodeSegmentNamesBothMarks() {
        let clipModel = clip(name: "part 1", video: video(), inPoint: 5, outPoint: 8)
        let item = ExportItem(source: URL(fileURLWithPath: "/media/target.mkv"),
                              displayName: "part 1", codec: "h264",
                              segments: [PlannedSegment(kind: .reEncode, range: 5..<9)],
                              index: Self.index, frameRate: "25/1")
        let report = PlanReport.make(prepared: prepared(
            target: clipModel, targetItem: item,
            fill: clipModel, fillItem: item, tracks: []))
        let reason = report.clips[0].segments?.first?.reason ?? ""
        #expect(reason.contains("in point is not a copy-safe keyframe"))
        #expect(reason.contains("out point is not a copy-safe keyframe"))
        #expect(report.clips[0].copiedFraction == 0)
    }

    // MARK: - Copy-safe keyframes

    /// The marks' copy boundaries: the pair an agent moves a mark to. The out pair
    /// brackets the kept range's exclusive end (45), not the inclusive out frame.
    @Test func copySafeKeyframesBracketBothMarks() {
        let keyframes = canonicalReport().clips[0].copySafeKeyframes
        #expect(keyframes == PlanReport.CopySafeKeyframes(
            beforeIn: 0, afterIn: 10, beforeOut: 40, afterOut: 50))
    }

    /// A side with no copy-safe keyframe reports null rather than the nearest wrong one.
    @Test func aMissingCopyBoundaryIsNull() {
        let flags = [false, true, false, false]
        #expect(PlanReport.nearestCopySafe(flags, from: 0, forward: false) == nil)
        #expect(PlanReport.nearestCopySafe(flags, from: 0, forward: true) == 1)
        #expect(PlanReport.nearestCopySafe(flags, from: 2, forward: true) == nil)
        #expect(PlanReport.nearestCopySafe(flags, from: 3, forward: false) == 1)
    }

    /// Every optional is written as `null`, never omitted, so a reader can index a field
    /// without first checking that the key exists.
    @Test func nullFieldsArePresentInTheEncodedDocument() throws {
        let json = try String(data: canonicalReport().jsonData(), encoding: .utf8) ?? ""
        #expect(json.contains("\"conformCrf\" : null"))
        #expect(json.contains("\"reason\" : null"))
        #expect(json.contains("\"segments\" : null"))
        #expect(json.contains("\"copySafeKeyframes\" : null"))
    }

    // MARK: - Shares and counts

    /// The copied share is duration-weighted through the index pts (GOPs are not
    /// uniform), and the frame count is what the export will write.
    @Test func copiedFractionAndExpectedFramesMeasureTheKeptRange() {
        let plan = canonicalReport().clips[0]
        #expect(plan.kept == PlanReport.Kept(inFrame: 5, outFrame: 44, frames: 40, seconds: 1.6))
        #expect(plan.copiedFraction == 0.75)     // 1.2 s copied of 1.6 s kept
        #expect(plan.expectedFrames == 40)
    }

    /// A conformed clip re-encodes whole: nothing is copied, it has no segments, and no
    /// copy boundary would shorten anything.
    @Test func aConformedClipReportsWhyItDoesNotMatch() {
        let plan = canonicalReport().clips[1]
        #expect(plan.treatment == .conform)
        #expect(plan.segments == nil)
        #expect(plan.copySafeKeyframes == nil)
        #expect(plan.copiedFraction == 0)
        #expect(plan.expectedFrames == 60)
        #expect(plan.reason == [PlanReport.Difference(property: "Pixel aspect ratio",
                                                      clip: "64:45", target: "1:1")])
    }

    /// A conform re-encodes to the **target's** frame rate, and an fps mismatch is one of
    /// the things that routes a clip here — so its count is the kept window at the target
    /// rate, never the source frames it is about to convert away from.
    @Test func aConformCountsFramesAtTheTargetRate() {
        // 60 source frames at 30 fps = 2 s, conformed to a 25 fps target = 50 frames.
        let source = video()
        var thirty = source
        thirty.frameRate = "30/1"
        let item = ExportItem(source: URL(fileURLWithPath: "/media/fill.mkv"), codec: "h264",
                              audioStart: 0, audioEnd: 2, audioDuration: 2,
                              conform: ConformEngine.VideoConform(sourceVideo: thirty,
                                                                  targetVideo: source))
        #expect(PlanReport.expectedFrames(item: item, kept: 0..<60, index: Self.index) == 50)
    }

    /// A truncated ending shortens the conform's input read, so the count follows the
    /// trimmed window rather than the kept range (issue #79).
    @Test func aTruncatedEndingShortensTheConformCount() {
        let item = ExportItem(source: URL(fileURLWithPath: "/media/fill.mkv"), codec: "h264",
                              audioStart: 0, audioEnd: 2.4, audioDuration: 2.4,
                              conform: ConformEngine.VideoConform(sourceVideo: video(),
                                                                  targetVideo: video(),
                                                                  trimEnd: 2.0))
        #expect(PlanReport.expectedFrames(item: item, kept: 0..<60, index: Self.index) == 50)
    }

    /// A field-coded (PAFF) source indexes fields, two per displayed frame (ADR-0022) —
    /// the marks stay in the job's own field coordinates, the output count is halved.
    @Test func aFieldCodedClipCountsFramesNotFields() {
        let item = ExportItem(source: URL(fileURLWithPath: "/media/target.mkv"),
                              codec: "h264",
                              segments: [PlannedSegment(kind: .copy, range: 0..<40)],
                              index: Self.index, frameRate: "25/1", fieldCoded: true)
        #expect(PlanReport.expectedFrames(item: item, kept: 0..<40, index: Self.index) == 20)
    }

    // MARK: - Output and audio

    /// A video-only output writes no audio at all, so the report carries no tracks for it —
    /// a resolved track list would read as a promise of audio in the file.
    @Test func aVideoOnlyOutputReportsNoAudioTracks() {
        let targetAudio = AudioProperties(codec: "ac3", sampleRate: 48000, channels: 2,
                                          bitrate: 384_000)
        let clipModel = clip(name: "part 1", video: video(), audio: targetAudio)
        let item = ExportItem(source: URL(fileURLWithPath: "/media/target.mkv"), codec: "h264",
                              segments: [PlannedSegment(kind: .copy, range: 0..<60)],
                              index: Self.index, frameRate: "25/1")
        var base = prepared(target: clipModel, targetItem: item, fill: clipModel, fillItem: item,
                            tracks: [AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2)])
        base.settings.type = .videoOnly
        let audio = PlanReport.make(prepared: base).audio
        #expect(audio.tracks == 0)
        #expect(audio.codec.in.isEmpty)
        #expect(audio.bitrate.in.isEmpty)
    }

    /// The output block echoes the settings the job resolved to, and `target` points at
    /// the clip whose spec the others conform to.
    @Test func theOutputBlockEchoesTheResolvedSettings() {
        let report = canonicalReport()
        #expect(report.version == 1)
        #expect(report.target == 0)
        #expect(report.output == PlanReport.Output(container: "mkv", type: "videoAndAudio",
                                                    conformCrf: nil))
    }

    /// Source rate beside output rate is the point of the audio block: it makes a
    /// 384k → 192k drop visible before the render rather than after it.
    @Test func audioPairsTheSourceRateWithTheOutputRate() {
        let audio = canonicalReport().audio
        #expect(audio.tracks == 1)
        #expect(audio.codec.in == ["ac3"])
        #expect(audio.codec.out == "ac3")
        #expect(audio.codec.fellBack == false)
        #expect(audio.bitrate.in == ["384k"])
        #expect(audio.bitrate.out == "192k")
    }

    /// A track the target clip doesn't feed, and a container that reports no rate, are
    /// both null — never a guessed number.
    @Test func anUnknownSourceRateIsNull() {
        let targetAudio = AudioProperties(codec: "ac3", sampleRate: 48000, channels: 2)
        let targetClip = clip(name: "part 1", video: video(), audio: targetAudio)
        let item = ExportItem(source: URL(fileURLWithPath: "/media/target.mkv"),
                              codec: "h264",
                              segments: [PlannedSegment(kind: .copy, range: 0..<60)],
                              index: Self.index, frameRate: "25/1")
        let track = AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2)
        let report = PlanReport.make(prepared: prepared(
            target: targetClip, targetItem: item, fill: targetClip, fillItem: item,
            tracks: [track, track]))
        #expect(report.audio.bitrate.in == [nil, nil])
        #expect(report.audio.codec.in == ["ac3", nil])
    }

    @Test func bitrateLabelsRoundToTheNearestKilobit() {
        #expect(PlanReport.bitrateLabel(384_000) == "384k")
        #expect(PlanReport.bitrateLabel(383_997) == "384k")
        #expect(PlanReport.bitrateLabel(192_000) == "192k")
    }

    /// The warnings are the run's own, in the run's own order — the report never
    /// re-derives them.
    @Test func warningsAreCarriedThrough() {
        let clipModel = clip(name: "part 1", video: video())
        let item = ExportItem(source: URL(fileURLWithPath: "/media/target.mkv"),
                              codec: "h264",
                              segments: [PlannedSegment(kind: .copy, range: 0..<60)],
                              index: Self.index, frameRate: "25/1")
        let report = PlanReport.make(prepared: prepared(
            target: clipModel, targetItem: item, fill: clipModel, fillItem: item,
            tracks: [], warnings: ["first", "second"]))
        #expect(report.warnings == ["first", "second"])
    }
}
