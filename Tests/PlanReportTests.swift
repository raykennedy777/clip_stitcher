import Testing
import Foundation
@testable import ClipStitcher

struct PlanReportTests {
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

    @Test func segmentsCarryHalfOpenRangesAndMeasuredSeconds() {
        let plan = canonicalReport().clips[0]
        #expect(plan.treatment == .smartRender)
        #expect(plan.segments?.map(\.kind) == [.reEncode, .copy, .reEncode])
        #expect(plan.segments?.map(\.frames) == [[5, 10], [10, 40], [40, 45]])
        #expect(plan.segments?.map(\.seconds) == [0.2, 1.2, 0.2])
        #expect(plan.reason == nil)
    }

    @Test func reEncodeSegmentsExplainThemselvesFromTheirPosition() {
        let segments = canonicalReport().clips[0].segments ?? []
        #expect(segments[0].reason
                == "in point is not a copy-safe keyframe; nearest copy-safe keyframe at or after it is 10")
        #expect(segments[1].reason == nil)
        #expect(segments[2].reason
                == "out point is not a copy-safe keyframe; nearest copy-safe keyframe at or before it is 40")
    }

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

    @Test func copySafeKeyframesBracketBothMarks() {
        let keyframes = canonicalReport().clips[0].copySafeKeyframes
        #expect(keyframes == PlanReport.CopySafeKeyframes(
            beforeIn: 0, afterIn: 10, beforeOut: 40, afterOut: 50))
    }

    @Test func aMissingCopyBoundaryIsNull() {
        let flags = [false, true, false, false]
        #expect(PlanReport.nearestCopySafe(flags, from: 0, forward: false) == nil)
        #expect(PlanReport.nearestCopySafe(flags, from: 0, forward: true) == 1)
        #expect(PlanReport.nearestCopySafe(flags, from: 2, forward: true) == nil)
        #expect(PlanReport.nearestCopySafe(flags, from: 3, forward: false) == 1)
    }

    @Test func nullFieldsArePresentInTheEncodedDocument() throws {
        let json = try String(data: canonicalReport().jsonData(), encoding: .utf8) ?? ""
        #expect(json.contains("\"conformCrf\" : null"))
        #expect(json.contains("\"reason\" : null"))
        #expect(json.contains("\"segments\" : null"))
        #expect(json.contains("\"copySafeKeyframes\" : null"))
    }

    @Test func copiedFractionAndExpectedFramesMeasureTheKeptRange() {
        let plan = canonicalReport().clips[0]
        #expect(plan.kept == PlanReport.Kept(inFrame: 5, outFrame: 44, frames: 40, seconds: 1.6))
        #expect(plan.copiedFraction == 0.75)
        #expect(plan.expectedFrames == 40)
    }

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

    @Test func aConformCountsFramesAtTheTargetRate() {
        let source = video()
        var thirty = source
        thirty.frameRate = "30/1"
        let item = ExportItem(source: URL(fileURLWithPath: "/media/fill.mkv"), codec: "h264",
                              audioStart: 0, audioEnd: 2, audioDuration: 2,
                              conform: ConformEngine.VideoConform(sourceVideo: thirty,
                                                                  targetVideo: source))
        #expect(PlanReport.expectedFrames(item: item, kept: 0..<60, index: Self.index) == 50)
    }

    @Test func aTruncatedEndingShortensTheConformCount() {
        let item = ExportItem(source: URL(fileURLWithPath: "/media/fill.mkv"), codec: "h264",
                              audioStart: 0, audioEnd: 2.4, audioDuration: 2.4,
                              conform: ConformEngine.VideoConform(sourceVideo: video(),
                                                                  targetVideo: video(),
                                                                  trimEnd: 2.0))
        #expect(PlanReport.expectedFrames(item: item, kept: 0..<60, index: Self.index) == 50)
    }

    @Test func aFieldCodedClipCountsFramesNotFields() {
        let item = ExportItem(source: URL(fileURLWithPath: "/media/target.mkv"),
                              codec: "h264",
                              segments: [PlannedSegment(kind: .copy, range: 0..<40)],
                              index: Self.index, frameRate: "25/1", fieldCoded: true)
        #expect(PlanReport.expectedFrames(item: item, kept: 0..<40, index: Self.index) == 20)
    }

    @Test func totalsSplitTheOutputFramesByHowTheyAreProduced() {
        let report = canonicalReport()
        #expect(report.totals == PlanReport.Totals(copiedFrames: 30, reEncodedFrames: 10,
                                                   conformedFrames: 60))
        let t = report.totals
        #expect(t.copiedFrames + t.reEncodedFrames + t.conformedFrames
                == report.clips.reduce(0) { $0 + $1.expectedFrames })
    }

    @Test func aFieldCodedSplitCountsFrames() {
        let item = ExportItem(source: URL(fileURLWithPath: "/media/target.mkv"),
                              codec: "h264",
                              segments: [PlannedSegment(kind: .copy, range: 0..<41)],
                              index: Self.index, frameRate: "25/1", fieldCoded: true)
        let split = PlanReport.frameSplit(item: item, kept: 0..<41, index: Self.index)
        #expect(split == PlanReport.Totals(copiedFrames: 20, reEncodedFrames: 0, conformedFrames: 0))
        #expect(PlanReport.expectedFrames(item: item, kept: 0..<41, index: Self.index) == 20)
    }

    @Test func totalsAreWrittenInTheEncodedDocument() throws {
        let json = try String(data: canonicalReport().jsonData(), encoding: .utf8) ?? ""
        #expect(json.contains("\"totals\""))
        #expect(json.contains("\"copiedFrames\" : 30"))
        #expect(json.contains("\"reEncodedFrames\" : 10"))
        #expect(json.contains("\"conformedFrames\" : 60"))
    }

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

    @Test func theOutputBlockEchoesTheResolvedSettings() {
        let report = canonicalReport()
        #expect(report.version == 1)
        #expect(report.target == 0)
        #expect(report.output == PlanReport.Output(container: "mkv", type: "videoAndAudio",
                                                    conformCrf: nil))
    }

    @Test func audioPairsTheSourceRateWithTheOutputRate() {
        let audio = canonicalReport().audio
        #expect(audio.tracks == 1)
        #expect(audio.codec.in == ["ac3"])
        #expect(audio.codec.out == "ac3")
        #expect(audio.codec.fellBack == false)
        #expect(audio.bitrate.in == ["384k"])
        #expect(audio.bitrate.out == "192k")
    }

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
