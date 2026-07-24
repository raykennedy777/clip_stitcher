import Testing
import Foundation
@testable import ClipStitcher

/// Exercises the Stitch Job contract behind the `clipstitch` CLI (issue #105) — all
/// pure, no file IO: JSON decode + structural validation, the mapping onto the GUI
/// model (`Clip`/`OutputSettings`), and the planned export items a job produces
/// through the same `ExportPlanner.planItem` the app calls. The schema is the public
/// cross-repo contract (docs/stitch-job.md); these tests are what pin it.
struct StitchJobTests {

    private func parse(_ json: String) throws -> StitchJob {
        try StitchJob.parse(Data(json.utf8))
    }

    // MARK: - Decode + structural validation

    @Test func parsesAFullJob() throws {
        let job = try parse("""
        {
          "version": 1,
          "clips": [
            { "path": "/media/target.mkv", "inFrame": 5, "outFrame": 44,
              "audioTracks": [0], "target": true },
            { "path": "/media/fill.mkv", "name": "Fill 1", "audioTracks": [1] }
          ],
          "output": { "container": "mkv", "type": "videoAndAudio" }
        }
        """)
        #expect(job.clips.count == 2)
        #expect(job.clips[0].inFrame == 5)
        #expect(job.clips[0].outFrame == 44)
        #expect(job.clips[0].audioTracks == [0])
        #expect(job.clips[1].name == "Fill 1")
        #expect(job.clips[1].inFrame == nil)
        #expect(job.targetIndex == 0)
    }

    @Test func malformedJSONIsRefusedLegibly() {
        #expect(throws: StitchJobError.self) { try self.parse("not json") }
        // The decode failure is reported as one line naming the path, never the raw
        // DecodingError dump — a script's stderr should be readable.
        do {
            _ = try parse("{\"version\": 1, \"clips\": [{ }]}")
            Issue.record("expected malformed")
        } catch let error as StitchJobError {
            guard case .malformed(let detail) = error else {
                Issue.record("expected .malformed, got \(error)")
                return
            }
            #expect(detail.contains("path"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func unknownVersionIsRefused() {
        #expect(throws: StitchJobError.unsupportedVersion(2)) {
            try self.parse("{\"version\": 2, \"clips\": [{\"path\": \"/a\", \"target\": true}]}")
        }
    }

    @Test func targetCardinalityIsExactlyOne() {
        #expect(throws: StitchJobError.noClips) {
            try self.parse("{\"version\": 1, \"clips\": []}")
        }
        #expect(throws: StitchJobError.noTarget) {
            try self.parse("{\"version\": 1, \"clips\": [{\"path\": \"/a\"}]}")
        }
        #expect(throws: StitchJobError.multipleTargets) {
            try self.parse("""
            {"version": 1, "clips": [{"path": "/a", "target": true},
                                     {"path": "/b", "target": true}]}
            """)
        }
    }

    @Test func frameRangesAreSanityChecked() {
        #expect(throws: StitchJobError.self) {
            try self.parse("""
            {"version": 1, "clips": [{"path": "/a", "inFrame": -1, "target": true}]}
            """)
        }
        #expect(throws: StitchJobError.self) {
            try self.parse("""
            {"version": 1, "clips": [{"path": "/a", "inFrame": 10, "outFrame": 9, "target": true}]}
            """)
        }
        // in == out is a legal single-frame keep, matching Clip.inPoint/outPoint.
        #expect((try? parse("""
        {"version": 1, "clips": [{"path": "/a", "inFrame": 10, "outFrame": 10, "target": true}]}
        """)) != nil)
    }

    @Test func negativeAudioStreamIndexIsRefused() {
        #expect(throws: StitchJobError.badAudioTrack(clip: 0, index: -1)) {
            try self.parse("""
            {"version": 1, "clips": [{"path": "/a", "audioTracks": [-1], "target": true}]}
            """)
        }
    }

    @Test func outputStringsMustBeExactRawValues() {
        #expect(throws: StitchJobError.unknownContainer("MKV")) {
            try self.parse("""
            {"version": 1, "clips": [{"path": "/a", "target": true}],
             "output": {"container": "MKV"}}
            """)
        }
        #expect(throws: StitchJobError.unknownOutputType("video")) {
            try self.parse("""
            {"version": 1, "clips": [{"path": "/a", "target": true}],
             "output": {"type": "video"}}
            """)
        }
    }

    // MARK: - Output settings mapping

    @Test func outputSettingsDefaultToConnectedMKV() throws {
        let job = try parse("{\"version\": 1, \"clips\": [{\"path\": \"/a\", \"target\": true}]}")
        let settings = try job.outputSettings()
        #expect(settings.mode == .connect)
        #expect(settings.container == .mkv)
        #expect(settings.type == .videoAndAudio)
        #expect(try StitchPipeline.requiredExtension(job: job) == "mkv")
    }

    @Test func outputSettingsCarryTheJobsChoices() throws {
        let job = try parse("""
        {"version": 1, "clips": [{"path": "/a", "target": true}],
         "output": {"container": "ts", "type": "videoOnly"}}
        """)
        let settings = try job.outputSettings()
        #expect(settings.mode == .connect)   // never anything else via the CLI
        #expect(settings.container == .ts)
        #expect(settings.type == .videoOnly)
        #expect(try StitchPipeline.requiredExtension(job: job) == "ts")
    }

    @Test func audioOnlyJobsImposeNoOutputExtension() throws {
        let job = try parse("""
        {"version": 1, "clips": [{"path": "/a", "target": true}],
         "output": {"type": "audioOnly"}}
        """)
        #expect(try StitchPipeline.requiredExtension(job: job) == nil)
    }

    // MARK: - Model mapping (job entry → Clip)

    private func probeResult(codec: String = "h264",
                             audioCodecs: [String] = ["aac"]) -> MediaProbe.Result {
        let video = VideoProperties(codec: codec, profile: "High", level: "41",
                                    width: 1920, height: 1080, frameRate: "25/1",
                                    pixelFormat: "yuv420p", fieldOrder: "progressive",
                                    sampleAspectRatio: "1:1", colorPrimaries: nil,
                                    colorTransfer: nil, colorRange: nil)
        let tracks = audioCodecs.map {
            AudioProperties(codec: $0, sampleRate: 48000, channels: 2, channelLayout: "stereo")
        }
        return MediaProbe.Result(video: video, audio: tracks.first, audioTracks: tracks,
                                 duration: 10, containerStart: 0)
    }

    @Test func modelClipCarriesProbeAndSelection() throws {
        let entry = StitchJob.JobClip(path: "/media/fill.mkv", inFrame: 3, outFrame: 7,
                                      audioTracks: [1])
        let clip = entry.modelClip(probe: probeResult(audioCodecs: ["mp2", "aac"]), frameCount: 250)
        #expect(clip.displayName == "fill.mkv")   // file name when no name given
        #expect(clip.video?.codec == "h264")
        #expect(clip.frameCount == 250)
        #expect(clip.inPoint == 3)
        #expect(clip.outPoint == 7)
        // The selection maps to own-stream slots at the Original mix — so the shared
        // AudioSourceResolver reads it exactly as it reads a GUI clip's (ADR-0014).
        #expect(clip.audioSelections == [.stream(1)])
        let sources = try AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError)
        #expect(sources == [.stream(1)])
    }

    @Test func omittedAudioTracksMeanAllOwnStreams() throws {
        let entry = StitchJob.JobClip(path: "/media/a.mkv", name: "A")
        let clip = entry.modelClip(probe: probeResult(audioCodecs: ["mp2", "aac"]), frameCount: 100)
        #expect(clip.displayName == "A")
        #expect(clip.audioSelections == nil)   // the GUI default: all own streams
        let sources = try AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError)
        #expect(sources == [.stream(0), .stream(1)])
    }

    // MARK: - Job → planned export items (the CLI's planning altitude, pure)

    /// 8 frames at 25 fps, keyframes at 0 and 4, no B-frames — the ExportPlannerTests
    /// index shape, reused so the verdicts here can't drift from the planner suite's.
    private let index = FrameIndex(
        pts: [0.0, 0.04, 0.08, 0.12, 0.16, 0.20, 0.24, 0.28],
        keyframeFlags: [true, false, false, false, true, false, false, false])

    @Test func jobPlansTargetAsSmartRenderAndNonMatchingAsConform() throws {
        let job = try parse("""
        {
          "version": 1,
          "clips": [
            { "path": "/media/target.mkv", "audioTracks": [0], "target": true },
            { "path": "/media/fill.mkv", "audioTracks": [1] }
          ]
        }
        """)
        let settings = try job.outputSettings()
        let targetClip = job.clips[0].modelClip(probe: probeResult(), frameCount: index.count)
        let fillClip = job.clips[1].modelClip(
            probe: probeResult(codec: "mpeg2video", audioCodecs: ["mp2", "aac"]),
            frameCount: index.count)

        func item(for clip: Clip) throws -> ExportItem {
            try ExportPlanner.planItem(
                for: ExportPlanner.ClipInput(
                    clip: clip, url: URL(fileURLWithPath: "/dev/null"), index: index,
                    containerStart: 0,
                    audioSources: AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError),
                    audioMixFilters: AudioSourceResolver.resolveMixFilters(for: clip)),
                target: targetClip, settings: settings)
        }

        // The target matches itself: a whole-clip keep plans as one pure copy (ADR-0009).
        let targetItem = try item(for: targetClip)
        #expect(targetItem.conform == nil)
        #expect(targetItem.segments == [PlannedSegment(kind: .copy, range: 0..<8)])
        #expect(targetItem.audioSources == [.stream(0)])

        // The MPEG-2 fill doesn't match the H.264 target: conformed to its spec
        // (ADR-0011), and its audio leg comes from the job-selected stream 1.
        let fillItem = try item(for: fillClip)
        #expect(fillItem.conform != nil)
        #expect(fillItem.conform?.targetVideo.codec == "h264")
        #expect(fillItem.audioSources == [.stream(1)])
    }

    @Test func inOutFramesBecomeTheKeptWindow() throws {
        let entry = StitchJob.JobClip(path: "/a.mkv", inFrame: 2, outFrame: 5, target: true)
        let clip = entry.modelClip(probe: probeResult(), frameCount: index.count)
        let item = try ExportPlanner.planItem(
            for: ExportPlanner.ClipInput(
                clip: clip, url: URL(fileURLWithPath: "/dev/null"), index: index,
                containerStart: 0,
                audioSources: AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError)),
            target: clip, settings: OutputSettings())
        // Frames [2, 5] kept: the window starts at pts[2] and ends at the out frame's
        // display end pts[6], the span every audio leg is forced to (ADR-0014, #75).
        #expect(item.audioStart == 0.08)
        #expect(item.audioEnd == 0.24)
        #expect(abs((item.audioDuration ?? 0) - 0.16) < 0.0001)
    }

    // MARK: - Output track derivation matches the GUI's (ADR-0014)

    @Test func outputTracksFollowTheRichestClipTargetFirst() throws {
        let target = StitchJob.JobClip(path: "/t.mkv", audioTracks: [0], target: true)
            .modelClip(probe: probeResult(audioCodecs: ["mp2"]), frameCount: 8)
        let fill = StitchJob.JobClip(path: "/f.mkv", audioTracks: [0, 1])
            .modelClip(probe: probeResult(audioCodecs: ["aac", "aac"]), frameCount: 8)
        let tracks = AudioSourceResolver.resolveOutputTracks(target: target, clips: [target, fill])
        // Two tracks (the fill selects two); track 1's format comes target-first.
        #expect(tracks.count == 2)
        #expect(tracks[0].sampleRate == 48000)
    }
}
