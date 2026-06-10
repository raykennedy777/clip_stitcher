import Testing
import Foundation
@testable import VidConform

/// Exercises the pure export planning behind the document's export entry point
/// (issue #28): the smart-render-vs-conform verdict matrix (ADR-0005 / ADR-0011) and
/// the assembled export items — no document, no file IO.
struct ExportPlannerTests {

    private func video(codec: String = "h264") -> VideoProperties {
        VideoProperties(codec: codec, profile: "High", level: "41", width: 1920, height: 1080,
                        frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: "progressive",
                        sampleAspectRatio: "1:1", colorPrimaries: nil, colorTransfer: nil,
                        colorRange: nil)
    }

    private func clip(video: VideoProperties?, inPoint: Int? = nil, outPoint: Int? = nil) -> Clip {
        var c = Clip(bookmark: Data(), displayName: "c")
        c.video = video
        c.inPoint = inPoint
        c.outPoint = outPoint
        return c
    }

    /// 8 frames at 25 fps, keyframes at 0 and 4, no B-frames (dts = pts).
    private let index = FrameIndex(
        pts: [0.0, 0.04, 0.08, 0.12, 0.16, 0.20, 0.24, 0.28],
        keyframeFlags: [true, false, false, false, true, false, false, false])

    // MARK: verdict matrix (ADR-0011)

    @Test func matchingClipIsSmartRendered() throws {
        let target = clip(video: video())
        let treatment = try ExportPlanner.videoTreatment(for: clip(video: video()),
                                                         target: target, index: index)
        guard case .smartRender(let segments, let encoder) = treatment else {
            Issue.record("expected smart render")
            return
        }
        // a whole-clip keep is a single pure copy (ADR-0009)
        #expect(segments == [PlannedSegment(kind: .copy, range: 0..<8)])
        #expect(!encoder.isEmpty)
    }

    @Test func nonMatchingClipIsConformed() throws {
        let target = clip(video: video(codec: "h264"))
        let source = clip(video: video(codec: "mpeg2video"))
        let treatment = try ExportPlanner.videoTreatment(for: source, target: target, index: index)
        #expect(treatment == .conform(ConformEngine.VideoConform(
            sourceVideo: video(codec: "mpeg2video"), targetVideo: video(codec: "h264"))))
    }

    @Test func noTargetClipMeansSmartRender() throws {
        // No target to conform to: every clip takes the smart-render path.
        let treatment = try ExportPlanner.videoTreatment(for: clip(video: video(codec: "hevc")),
                                                         target: nil, index: index)
        guard case .smartRender = treatment else {
            Issue.record("expected smart render")
            return
        }
    }

    @Test func clipWithoutVideoIsSmartRendered() throws {
        // No probed clip video to compare: the conform verdict can't fire (it needs
        // both specs); the clip takes the smart-render path, as before the extraction.
        let treatment = try ExportPlanner.videoTreatment(for: clip(video: nil),
                                                         target: clip(video: video()), index: index)
        guard case .smartRender = treatment else {
            Issue.record("expected smart render")
            return
        }
    }

    @Test func collapsedKeptRangeThrowsInvalidPlan() {
        // An inverted in/out keeps nothing (outFrame is inclusive, so only out < in
        // collapses) → the planner refuses (ExportError.invalidPlan).
        let c = clip(video: video(), inPoint: 5, outPoint: 2)
        #expect(throws: ExportError.self) {
            try ExportPlanner.videoTreatment(for: c, target: nil, index: index)
        }
    }

    // MARK: item assembly

    @Test func smartRenderedItemCarriesPlanWindowAndSources() throws {
        // Kept range frames 2…6 on a 0-start container: window in pts, duration = kept span.
        let input = ExportPlanner.ClipInput(
            clip: clip(video: video(), inPoint: 2, outPoint: 6),
            url: URL(fileURLWithPath: "/tmp/a.mp4"), index: index,
            containerStart: 0, audioSources: [.stream(0), nil])
        let item = try ExportPlanner.planItem(for: input, target: nil)
        #expect(item.conform == nil)
        #expect(!item.segments.isEmpty)
        #expect(item.codec == "h264")
        #expect(item.source.path == "/tmp/a.mp4")
        #expect(item.audioStart == 0.08)
        #expect(item.audioEnd == 0.24)
        #expect(abs((item.audioDuration ?? 0) - 0.16) < 1e-9)
        #expect(item.audioSources == [.stream(0), nil])
        #expect(!item.encoder.isEmpty)
    }

    @Test func conformedItemCarriesTheTargetCodecAndNoSegments() throws {
        // The conformed piece is produced at the target spec, so the item's codec —
        // what reaches the concat — is the target's, not the source's.
        let input = ExportPlanner.ClipInput(
            clip: clip(video: video(codec: "mpeg2video")),
            url: URL(fileURLWithPath: "/tmp/b.mpg"), index: index,
            containerStart: 0.24, audioSources: [.stream(0)])
        let item = try ExportPlanner.planItem(for: input, target: clip(video: video(codec: "h264")))
        #expect(item.conform != nil)
        #expect(item.segments.isEmpty)
        #expect(item.codec == "h264")
        // open ends: no seek window, duration spans first frame to one slot past the last
        #expect(item.audioStart == nil)
        #expect(item.audioEnd == nil)
    }

    // MARK: cut-only (issue #31 / ADR-0018)

    private func settings(mode: OutputMode, rendering: SeparateRendering) -> OutputSettings {
        var s = OutputSettings()
        s.mode = mode
        s.rendering = rendering
        return s
    }

    @Test func effectiveTargetSurvivesEveryCombinationExceptSeparateCutOnly() {
        let target = clip(video: video())
        #expect(ExportPlanner.effectiveTarget(target, settings: settings(mode: .connect, rendering: .conformToTarget)) == target)
        #expect(ExportPlanner.effectiveTarget(target, settings: settings(mode: .connect, rendering: .cutOnly)) == target)
        #expect(ExportPlanner.effectiveTarget(target, settings: settings(mode: .separate, rendering: .conformToTarget)) == target)
        #expect(ExportPlanner.effectiveTarget(target, settings: settings(mode: .separate, rendering: .cutOnly)) == nil)
    }

    @Test func cutOnlyNeverConformsAMismatchingClip() throws {
        // The same mismatch that conforms under conform-to-target smart-renders against
        // itself under cut-only — encoder args from the clip's own codec (ADR-0018).
        let input = ExportPlanner.ClipInput(
            clip: clip(video: video(codec: "mpeg2video")),
            url: URL(fileURLWithPath: "/tmp/b.mpg"), index: index,
            containerStart: 0, audioSources: [.stream(0)])
        let target = clip(video: video(codec: "h264"))
        let item = try ExportPlanner.planItem(for: input, target: target,
                                              settings: settings(mode: .separate, rendering: .cutOnly))
        #expect(item.conform == nil)
        #expect(!item.segments.isEmpty)
        #expect(item.codec == "mpeg2video")
        #expect(item.encoder.contains("mpeg2video"))
    }

    @Test func separateConformToTargetStillConforms() throws {
        let input = ExportPlanner.ClipInput(
            clip: clip(video: video(codec: "mpeg2video")),
            url: URL(fileURLWithPath: "/tmp/b.mpg"), index: index,
            containerStart: 0, audioSources: [.stream(0)])
        let item = try ExportPlanner.planItem(for: input, target: clip(video: video(codec: "h264")),
                                              settings: settings(mode: .separate, rendering: .conformToTarget))
        #expect(item.conform != nil)
    }

    // MARK: frame duration (moved from the document with the planning)

    @Test func frameDurationParsesARationalRate() {
        #expect(ExportPlanner.frameDuration("25/1") == 0.04)
        #expect(ExportPlanner.frameDuration("30000/1001") == 1001.0 / 30000.0)
        #expect(ExportPlanner.frameDuration(nil) == nil)
        #expect(ExportPlanner.frameDuration("") == nil)
        #expect(ExportPlanner.frameDuration("25") == nil)
        #expect(ExportPlanner.frameDuration("0/1") == nil)
    }
}
