import Testing
import Foundation
@testable import ClipStitcher

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

    @Test func clipWithoutVideoRefusesToPlan() {
        // No probed clip video (still importing, or import failed): planning would
        // default the smart-render encoder to libx264 and silently re-encode the source
        // wrong (issue #78), so the planner refuses rather than reaching encoder
        // selection with `video == nil`.
        #expect(throws: ExportError.self) {
            try ExportPlanner.videoTreatment(for: clip(video: nil),
                                             target: clip(video: video()), index: index)
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
        // Kept range frames 2…6 on a 0-start container (pts 0.08…0.24, next frame 0.28).
        // The window ends at the out frame's display end (pts[7] = 0.28), so the forced
        // audio duration equals the kept video span, not one frame short (issue #75).
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
        #expect(abs((item.audioEnd ?? 0) - 0.28) < 1e-9)   // out frame's display end (pts[7])
        #expect(abs((item.audioDuration ?? 0) - 0.20) < 1e-9)   // pts[7] - pts[2] = kept video span
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

    @Test func inOutPastTheIndexEndThrowsInsteadOfTrapping() {
        // Belt-and-braces (issue #74): a stored out point that outran a re-imported
        // shorter index must refuse with invalidPlan, never trap the pts subscript.
        let input = ExportPlanner.ClipInput(
            clip: clip(video: video(), inPoint: 2, outPoint: 99),
            url: URL(fileURLWithPath: "/tmp/a.mp4"), index: index,
            containerStart: 0, audioSources: [.stream(0)])
        #expect(throws: ExportError.self) {
            try ExportPlanner.planItem(for: input, target: nil)
        }
    }

    @Test func inPointPastTheIndexEndThrowsInsteadOfTrapping() {
        let input = ExportPlanner.ClipInput(
            clip: clip(video: video(), inPoint: 42, outPoint: nil),
            url: URL(fileURLWithPath: "/tmp/a.mp4"), index: index,
            containerStart: 0, audioSources: [.stream(0)])
        #expect(throws: ExportError.self) {
            try ExportPlanner.planItem(for: input, target: nil)
        }
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

    // MARK: copy/re-encode share (issue #15)

    /// Shares are duration-weighted through the pts, never segment-count-weighted: with
    /// deliberately non-uniform frame spacing (1 s frames then 0.5 s frames) the plan
    /// `[re-encode 1..<4, copy 4..<8, re-encode 8..<9]` is 1-of-3 segments but
    /// 2.0 s of 5.5 s copied.
    @Test func copyShareIsDurationWeightedNotSegmentCounted() throws {
        let uneven = FrameIndex(
            pts: [0, 1, 2, 3, 4, 4.5, 5, 5.5, 6, 6.5],
            keyframeFlags: [true, false, false, false, true, false, false, false, true, false])
        let share = try #require(ExportPlanner.copyShare(
            for: clip(video: video(), inPoint: 1, outPoint: 8),
            target: clip(video: video()), settings: OutputSettings(), index: uneven))
        #expect(share.copiedSeconds == 2.0)
        #expect(share.totalSeconds == 5.5)
        #expect(abs(share.copiedFraction - 2.0 / 5.5) < 1e-9)
    }

    /// The open-GOP poster child (issue #15): every cut-range keyframe carries leading
    /// pictures, so no copy span can start and the whole kept range re-encodes — 0% copied.
    @Test func copyShareIsZeroWhenNoCopySafePointExists() throws {
        // Frame 3 presents before keyframe 4 but decodes after it (dts .16 > .12):
        // keyframe 4 has a leading picture, and the only count-0 keyframe (0) sits
        // before the in point.
        let openGOP = FrameIndex(
            pts: [0, 0.04, 0.08, 0.12, 0.16, 0.20, 0.24, 0.28],
            dts: [0, 0.04, 0.08, 0.16, 0.12, 0.20, 0.24, 0.28],
            keyframeFlags: [true, false, false, false, true, false, false, false])
        let share = try #require(ExportPlanner.copyShare(
            for: clip(video: video(), inPoint: 1, outPoint: 6),
            target: clip(video: video()), settings: OutputSettings(), index: openGOP))
        #expect(share.copiedSeconds == 0)
        #expect(share.totalSeconds > 0)
        #expect(share.copiedFraction == 0)
    }

    /// A conform-routed clip is a full re-encode of its kept window: 0% copied over the
    /// whole-clip duration (the last frame contributes its predecessor's delta).
    @Test func copyShareOfAConformedClipIsZeroOverItsKeptWindow() throws {
        let share = try #require(ExportPlanner.copyShare(
            for: clip(video: video(codec: "mpeg2video")),
            target: clip(video: video(codec: "h264")), settings: OutputSettings(), index: index))
        #expect(share.copiedSeconds == 0)
        #expect(abs(share.totalSeconds - 0.32) < 1e-9)
    }

    /// Cut-only severs the target (ADR-0018), so the same mismatching clip smart-renders
    /// against itself — a whole-clip keep is a pure copy, 100 % copied.
    @Test func copyShareUnderCutOnlyIgnoresTheTarget() throws {
        let share = try #require(ExportPlanner.copyShare(
            for: clip(video: video(codec: "mpeg2video")),
            target: clip(video: video(codec: "h264")),
            settings: settings(mode: .separate, rendering: .cutOnly), index: index))
        #expect(share.copiedFraction == 1.0)
    }

    // MARK: damage repair threading (#47)

    /// A 100-frame, 25 fps index with keyframes every 25 — wide enough for a zone to
    /// land mid-copy.
    private let longIndex = FrameIndex(
        pts: (0..<100).map { Double($0) * 0.04 },
        keyframeFlags: (0..<100).map { $0 % 25 == 0 })

    private func damagedClip(zones: [DamageZone]) -> Clip {
        var c = clip(video: video())
        c.damageZones = zones
        return c
    }

    /// A recorded zone reaches the smart-render plan as a repaired re-encode segment
    /// extending to the surrounding copy-safe boundaries; without zones the plan is
    /// today's, byte for byte.
    @Test func damageZonesForceRepairedSegmentsIntoTheVerdict() throws {
        let zone = DamageZone(start: 1.6, end: 1.8, affectsVideo: true)
        let treatment = try ExportPlanner.videoTreatment(
            for: damagedClip(zones: [zone]), target: nil, index: longIndex, containerStart: 0)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments == [
            PlannedSegment(kind: .copy, range: 0..<25, outCutKeyframe: 25),
            PlannedSegment(kind: .reEncode, range: 25..<50, damage: [zone]),
            PlannedSegment(kind: .copy, range: 50..<100),
        ])
    }

    /// A scanned-clean clip (zones == []) and an unscanned clip (nil) both plan
    /// exactly as before repair existed.
    @Test func cleanAndUnscannedClipsPlanAsToday() throws {
        let plain = try ExportPlanner.videoTreatment(
            for: clip(video: video()), target: nil, index: longIndex, containerStart: 0)
        let clean = try ExportPlanner.videoTreatment(
            for: damagedClip(zones: []), target: nil, index: longIndex, containerStart: 0)
        #expect(plain == clean)
        guard case .smartRender(let segments, _) = plain else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments == [PlannedSegment(kind: .copy, range: 0..<100)])
    }

    /// The zone times are container-start-relative; the planner maps them through the
    /// index's absolute pts by adding the container start.
    @Test func zoneMappingHonorsTheContainerStart() throws {
        let shifted = FrameIndex(
            pts: (0..<100).map { 1.44 + Double($0) * 0.04 },
            keyframeFlags: (0..<100).map { $0 % 25 == 0 })
        let zone = DamageZone(start: 1.6, end: 1.8, affectsVideo: true)   // abs 3.04–3.24
        let treatment = try ExportPlanner.videoTreatment(
            for: damagedClip(zones: [zone]), target: nil, index: shifted, containerStart: 1.44)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        // abs 3.04 is frame 40 — the repair lands in [25, 50). Mapping the zone's
        // 1.6 as absolute time (frame 4) would have put it in [0, 25) instead.
        #expect(segments.contains(PlannedSegment(kind: .reEncode, range: 25..<50, damage: [zone])))
    }

    /// A repaired span counts as re-encoded in the copy share — the Output view's
    /// numbers reflect the repair work.
    @Test func copyShareCountsRepairedSpansAsReencoded() throws {
        let zone = DamageZone(start: 1.6, end: 1.8, affectsVideo: true)
        let whole = try #require(ExportPlanner.copyShare(
            for: clip(video: video()), target: nil, settings: OutputSettings(), index: longIndex))
        let repaired = try #require(ExportPlanner.copyShare(
            for: damagedClip(zones: [zone]), target: nil, settings: OutputSettings(),
            index: longIndex, containerStart: 0))
        #expect(whole.copiedFraction == 1.0)
        #expect(repaired.copiedFraction < 1.0)
        #expect(repaired.totalSeconds == whole.totalSeconds)
    }

    /// A smart-rendered item carries the container start and source rate the repaired
    /// segments execute with.
    @Test func plannedItemCarriesContainerStartAndFrameRate() throws {
        let zone = DamageZone(start: 1.6, end: 1.8, affectsVideo: true)
        let item = try ExportPlanner.planItem(
            for: ExportPlanner.ClipInput(clip: damagedClip(zones: [zone]),
                                         url: URL(fileURLWithPath: "/clips/in.ts"),
                                         index: longIndex, containerStart: 1.44,
                                         audioSources: [.stream(0)]),
            target: nil)
        #expect(item.containerStart == 1.44)
        #expect(item.frameRate == "25/1")
        // The MKV copy cut needs the pts refill whenever the *source* is damaged —
        // even a clean kept window muxes the discarded segments (issue #47).
        #expect(item.sourceDamaged)
    }

    /// A conform-routed clip's verdict carries its video-affecting zones (issue #48) —
    /// the chain drops those spans before its fps fill; audio-only gaps stay out.
    @Test func conformedVerdictCarriesTheDamageZones() throws {
        let zone = DamageZone(start: 1.6, end: 1.8, affectsVideo: true)
        var source = clip(video: video(codec: "mpeg2video"))
        source.damageZones = [zone, DamageZone(start: 2.0, end: 3.0, affectsVideo: false)]
        let treatment = try ExportPlanner.videoTreatment(
            for: source, target: clip(video: video()), index: index)
        guard case .conform(let conform) = treatment else {
            Issue.record("expected conform")
            return
        }
        #expect(conform.damage == [zone])
    }

    // MARK: repair report (#47)

    @Test func repairReportListsVideoZonesInTheKeptWindow() {
        let zones = [
            DamageZone(start: 95.5, end: 96.0, affectsVideo: true),
            DamageZone(start: 4774.84, end: 4775.5, affectsVideo: true),
            DamageZone(start: 200.0, end: 200.5, affectsVideo: false),   // audio-only: out
        ]
        #expect(ExportPlanner.repairReport(clipName: "match.ts", zones: zones,
                                           windowStart: nil, windowEnd: nil)
            == "Repaired 2 damage zones in “match.ts” at 1:35, 1:19:34.")
        #expect(ExportPlanner.repairReport(clipName: "match.ts", zones: [zones[0]],
                                           windowStart: nil, windowEnd: nil)
            == "Repaired a damage zone in “match.ts” at 1:35.")
    }

    @Test func repairReportNamesATruncatedEnding() {
        // A truncated ending is named — not counted — from the single classification (`trimEnd`),
        // never re-derived from window proximity, so the report names exactly what the engine
        // trimmed (issue #79). Here the ending zone starts at 599.6, so `trimEnd == 599.6`.
        let ending = [DamageZone(start: 599.6, end: 600.0, affectsVideo: true)]
        #expect(ExportPlanner.repairReport(clipName: "live.ts", zones: ending,
                                           windowStart: nil, windowEnd: 600.0, trimEnd: 599.6)
            == "Repaired a truncated ending in “live.ts”.")
        // An interior zone plus the truncated ending: the ending is called out alongside.
        let mixed = [DamageZone(start: 95.5, end: 96.0, affectsVideo: true)] + ending
        #expect(ExportPlanner.repairReport(clipName: "live.ts", zones: mixed,
                                           windowStart: nil, windowEnd: 600.0, trimEnd: 599.6)
            == "Repaired a damage zone in “live.ts” at 1:35 and a truncated ending.")
        let twoPlus = [
            DamageZone(start: 95.5, end: 96.0, affectsVideo: true),
            DamageZone(start: 300.0, end: 300.5, affectsVideo: true),
        ] + ending
        #expect(ExportPlanner.repairReport(clipName: "live.ts", zones: twoPlus,
                                           windowStart: nil, windowEnd: 600.0, trimEnd: 599.6)
            == "Repaired 2 damage zones in “live.ts” at 1:35, 5:00 and a truncated ending.")
    }

    /// The report consumes the SAME truncated-ending decision the engine trims by, so message
    /// and engine can never disagree (issue #79). A zone the engine does NOT trim — no `trimEnd`,
    /// e.g. an interior out point landing just after a real interior zone — is counted as an
    /// ordinary repaired zone, never named as a truncated ending (the old window-proximity
    /// predicate would have mis-named it). A zone the engine trims is named, not counted.
    @Test func repairReportMatchesTheEngineTrimDecision() {
        // Same trailing zone, but `trimEnd == nil` (the window didn't reach the file end): the
        // zone is a plain interior repair, not a truncated ending.
        let ending = [DamageZone(start: 599.6, end: 600.0, affectsVideo: true)]
        #expect(ExportPlanner.repairReport(clipName: "c", zones: ending,
                                           windowStart: nil, windowEnd: 600.0, trimEnd: nil)
            == "Repaired a damage zone in “c” at 9:59.")
        // With the trim, the same zone is named and dropped from the count.
        #expect(ExportPlanner.repairReport(clipName: "c", zones: ending,
                                           windowStart: nil, windowEnd: 600.0, trimEnd: 599.6)
            == "Repaired a truncated ending in “c”.")
    }

    /// Naming survives a nil probed duration on the whole-file Doctor path (issue #79): the
    /// truncated ending comes from the engine's index-based `trimEnd`, not the container
    /// duration, so a nil `windowEnd` no longer silently drops the "truncated ending" wording.
    @Test func repairReportNamesATruncatedEndingWithNilDuration() {
        let ending = [DamageZone(start: 4774.84, end: 4775.5, affectsVideo: true)]
        #expect(ExportPlanner.repairReport(clipName: "c", zones: ending,
                                           windowStart: nil, windowEnd: nil, trimEnd: 4774.84)
            == "Repaired a truncated ending in “c”.")
    }

    /// A genuine EOF zone (start ≈ lastPts) isn't dropped from the report when a TS-probed
    /// `windowEnd` undershoots the true tail: the inclusion filter carries a one-frame slack
    /// (issue #79). Here the zone starts a hair past the undershooting window end.
    @Test func repairReportKeepsAnEofZoneWhenDurationUndershoots() {
        let ending = [DamageZone(start: 600.02, end: 600.1, affectsVideo: true)]
        #expect(ExportPlanner.repairReport(clipName: "c", zones: ending,
                                           windowStart: nil, windowEnd: 600.0, trimEnd: 600.02,
                                           frameInterval: 0.04)
            == "Repaired a truncated ending in “c”.")
    }

    @Test func repairReportFiltersZonesOutsideTheKeptWindow() {
        let zones = [
            DamageZone(start: 95.5, end: 96.0, affectsVideo: true),
            DamageZone(start: 500.0, end: 501.0, affectsVideo: true),
        ]
        // Window [400, 600): only the second zone was in the export.
        #expect(ExportPlanner.repairReport(clipName: "c", zones: zones,
                                           windowStart: 400, windowEnd: 600)
            == "Repaired a damage zone in “c” at 8:20.")
        // Nothing in the window — no report.
        #expect(ExportPlanner.repairReport(clipName: "c", zones: zones,
                                           windowStart: 1000, windowEnd: nil) == nil)
        #expect(ExportPlanner.repairReport(clipName: "c", zones: nil,
                                           windowStart: nil, windowEnd: nil) == nil)
        #expect(ExportPlanner.repairReport(clipName: "c", zones: [],
                                           windowStart: nil, windowEnd: nil) == nil)
    }

    // MARK: truncated-ending classification (#79)

    /// The low-level gate: a truncated ending needs the kept window to actually reach the file
    /// end AND a video zone to reach it within one frame interval (issue #79). `fileEnd` here is
    /// 0.32 (lastPts 0.28 + one 0.04 interval), matching the detector's genuine EOF zone end.
    @Test func truncatedEndingTrimGatesOnFileEndAndAOneIntervalMargin() {
        let eof = [DamageZone(start: 0.28, end: 0.32, affectsVideo: true)]
        // Reaches the file end, zone reaches it within one interval → trims to the zone start.
        #expect(ExportPlanner.truncatedEndingTrim(
            zones: eof, windowStart: nil, fileEnd: 0.32,
            reachesFileEnd: true, frameInterval: 0.04) == 0.28)
        // Same zone, but the window does NOT reach the file end (an interior out point): no trim,
        // however close the zone sits to the end — the fix for the spurious interior trim.
        #expect(ExportPlanner.truncatedEndingTrim(
            zones: eof, windowStart: nil, fileEnd: 0.32,
            reachesFileEnd: false, frameInterval: 0.04) == nil)
        // A zone ending well before the file end (0.12 vs 0.32) is interior even at the file end —
        // the one-interval margin, not the old 1.0 s that would have called this trailing.
        #expect(ExportPlanner.truncatedEndingTrim(
            zones: [DamageZone(start: 0.08, end: 0.12, affectsVideo: true)],
            windowStart: nil, fileEnd: 0.32, reachesFileEnd: true, frameInterval: 0.04) == nil)
        // A zone spanning the whole window would leave nothing — not a trim.
        #expect(ExportPlanner.truncatedEndingTrim(
            zones: [DamageZone(start: 0.10, end: 0.32, affectsVideo: true)],
            windowStart: 0.10, fileEnd: 0.32, reachesFileEnd: true, frameInterval: 0.04) == nil)
        // Audio-only trailing gap: no video trim (the audio legs silence-fill it).
        #expect(ExportPlanner.truncatedEndingTrim(
            zones: [DamageZone(start: 0.28, end: 0.32, affectsVideo: false)],
            windowStart: nil, fileEnd: 0.32, reachesFileEnd: true, frameInterval: 0.04) == nil)
    }

    /// The clip-level helper resolves `reachesFileEnd` from the out point: an open out (or an
    /// out on the last frame) runs to EOF and can trim; an interior out never trims (issue #79).
    @Test func truncatedEndingTrimForClipReachesFileEndOnlyAtEOF() {
        let eof = [DamageZone(start: 0.28, end: 0.32, affectsVideo: true)]
        // Open out point (nil): the whole tail is kept → the EOF zone trims.
        var openOut = clip(video: video()); openOut.damageZones = eof
        #expect(ExportPlanner.truncatedEndingTrim(
            for: openOut, index: index, containerStart: 0, windowStart: nil) == 0.28)
        // Out point on the last frame (7 of 8): still reaches EOF → trims.
        var lastFrameOut = clip(video: video(), outPoint: 7); lastFrameOut.damageZones = eof
        #expect(ExportPlanner.truncatedEndingTrim(
            for: lastFrameOut, index: index, containerStart: 0, windowStart: nil) == 0.28)
        // Interior out point (frame 3): does NOT reach EOF → no trim, even with the tail zone.
        var interiorOut = clip(video: video(), outPoint: 3); interiorOut.damageZones = eof
        #expect(ExportPlanner.truncatedEndingTrim(
            for: interiorOut, index: index, containerStart: 0, windowStart: nil) == nil)
    }

    /// `planItem` wires the single classification onto both the conform (`trimEnd`, consumed by
    /// the executor) and the item (`truncatedEndingTrim`, consumed by the report) — decided once
    /// (issue #79). A conformed clip whose out point reaches an EOF zone carries the trim; an
    /// interior out point does not.
    @Test func planItemCarriesTheTruncatedEndingTrim() throws {
        let target = clip(video: video(codec: "h264"))
        let eof = [DamageZone(start: 0.28, end: 0.32, affectsVideo: true)]
        var src = clip(video: video(codec: "mpeg2video")); src.damageZones = eof
        let inputEof = ExportPlanner.ClipInput(clip: src, url: URL(fileURLWithPath: "/x.ts"),
                                               index: index, containerStart: 0, audioSources: [])
        let item = try ExportPlanner.planItem(for: inputEof, target: target)
        #expect(item.truncatedEndingTrim == 0.28)
        #expect(item.conform?.trimEnd == 0.28)

        var interior = clip(video: video(codec: "mpeg2video"), outPoint: 3); interior.damageZones = eof
        let inputInterior = ExportPlanner.ClipInput(clip: interior, url: URL(fileURLWithPath: "/x.ts"),
                                                    index: index, containerStart: 0, audioSources: [])
        let itemInterior = try ExportPlanner.planItem(for: inputInterior, target: target)
        #expect(itemInterior.truncatedEndingTrim == nil)
        #expect(itemInterior.conform?.trimEnd == nil)
    }

    /// The Output warning fires only when re-encode *dominates* (> 50 % of output
    /// duration) — boundary slivers on closed-GOP sources must stay quiet.
    @Test func reencodeWarningFiresOnlyAboveTheDominanceThreshold() {
        let dominated = [ExportPlanner.CopyShare(copiedSeconds: 0, totalSeconds: 28)]
        #expect(ExportPlanner.reencodeDominanceWarning(shares: dominated)
            == "~28 s of 28 s will be re-encoded — little of this export can be stream-copied untouched.")
        let slivers = [ExportPlanner.CopyShare(copiedSeconds: 26, totalSeconds: 28)]
        #expect(ExportPlanner.reencodeDominanceWarning(shares: slivers) == nil)
        // exactly half is not "dominates"
        let half = [ExportPlanner.CopyShare(copiedSeconds: 14, totalSeconds: 28)]
        #expect(ExportPlanner.reencodeDominanceWarning(shares: half) == nil)
        #expect(ExportPlanner.reencodeDominanceWarning(shares: []) == nil)
    }

    // MARK: field-coded copy-only invariant (issue #96)

    private func fieldCodedClip(codec: String = "h264",
                                inPoint: Int? = nil, outPoint: Int? = nil) -> Clip {
        var c = clip(video: video(codec: codec), inPoint: inPoint, outPoint: outPoint)
        c.fieldCoded = true
        return c
    }

    /// On the 8-frame index (count-0 keyframes at 0 and 4, dts = pts) the copy-valid
    /// marks are in ∈ {0, 4} and out ∈ {3} (or nil = EOF) — exactly what the cut
    /// editor's snapping produces (`CopyCutSnapper`). A field-coded H.264 clip cut on
    /// those boundaries plans copy segments only and passes the invariant.
    @Test func fieldCodedClipWithSnappedCutsPlansCopyOnly() throws {
        let headKeep = try ExportPlanner.videoTreatment(
            for: fieldCodedClip(inPoint: 0, outPoint: 3), target: nil, index: index)
        guard case .smartRender(let headSegments, _) = headKeep else {
            Issue.record("expected smart render")
            return
        }
        #expect(headSegments == [PlannedSegment(kind: .copy, range: 0..<4, outCutKeyframe: 4)])

        let tailKeep = try ExportPlanner.videoTreatment(
            for: fieldCodedClip(inPoint: 4), target: nil, index: index)
        guard case .smartRender(let tailSegments, _) = tailKeep else {
            Issue.record("expected smart render")
            return
        }
        #expect(tailSegments == [PlannedSegment(kind: .copy, range: 4..<8)])
    }

    /// A mid-GOP out point on a field-coded H.264 clip would need a `.reEncode` edge —
    /// on this clip that can only be a programming error (the editor snaps every mark;
    /// re-encoding PAFF is structurally broken, ADR-0022), so the planner refuses with
    /// `fieldCodedPlanNotCopyOnly` instead of silently planning the re-encode.
    @Test func fieldCodedMidGOPCutIsAProgrammingErrorNotAReencode() {
        do {
            _ = try ExportPlanner.videoTreatment(
                for: fieldCodedClip(inPoint: 0, outPoint: 5), target: nil, index: index)
            Issue.record("expected the copy-only invariant to refuse the plan")
        } catch let error as ExportError {
            guard case .fieldCodedPlanNotCopyOnly = error else {
                Issue.record("expected fieldCodedPlanNotCopyOnly, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ExportError, got \(error)")
        }
    }

    /// A progressive clip is untouched by the invariant: the same mid-GOP cut still
    /// plans its partial-GOP re-encode edge exactly as before (ADR-0009).
    @Test func progressiveMidGOPCutStillPlansReencodeEdges() throws {
        let treatment = try ExportPlanner.videoTreatment(
            for: clip(video: video(), inPoint: 2), target: nil, index: index)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments == [
            PlannedSegment(kind: .reEncode, range: 2..<4),
            PlannedSegment(kind: .copy, range: 4..<8),
        ])
    }

    /// A field-coded clip in a codec the copy-cut route doesn't cover (non-H.264 — the
    /// shared `FieldCodedSupport` gate) keeps today's warn-only behavior: the source row
    /// warns, the editor doesn't snap, and the planner still plans re-encode edges for
    /// its mid-GOP cuts — the invariant never fires for it.
    @Test func fieldCodedNonH264KeepsTodaysReencodeEdges() throws {
        let treatment = try ExportPlanner.videoTreatment(
            for: fieldCodedClip(codec: "mpeg2video", inPoint: 2), target: nil, index: index)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments == [
            PlannedSegment(kind: .reEncode, range: 2..<4),
            PlannedSegment(kind: .copy, range: 4..<8),
        ])
    }

    /// A field-coded clip exported whole (no trims) is a single pure copy — the
    /// plain-remux path — and must sail through the invariant unchanged.
    @Test func fieldCodedWholeClipKeepStaysAPureCopy() throws {
        let treatment = try ExportPlanner.videoTreatment(
            for: fieldCodedClip(), target: nil, index: index)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments == [PlannedSegment(kind: .copy, range: 0..<8)])
    }

    /// A field-coded H.264 clip with the interior zone from the repair tests recorded —
    /// on `longIndex` (keyframes every 25) the zone spans frames 40–45.
    private func damagedFieldCodedClip(inPoint: Int? = nil, outPoint: Int? = nil) -> Clip {
        var c = fieldCodedClip(inPoint: inPoint, outPoint: outPoint)
        c.damageZones = [DamageZone(start: 1.6, end: 1.8, affectsVideo: true)]
        return c
    }

    /// Damage on the copy-cut route copies through **verbatim** (issue #96): an `.export`
    /// plan never repairs a field-coded H.264 clip — a repaired `.reEncode` segment would
    /// be a structurally broken PAFF re-encode (ADR-0022) — so recorded zones must not
    /// force repair segments (which would trip the invariant and dead-end the export with
    /// a re-mark suggestion that can't help). The workflow is Clip Doctor first; the
    /// whole-clip keep stays a single pure copy.
    @Test func fieldCodedDamagedClipExportsItsDamageVerbatim() throws {
        let treatment = try ExportPlanner.videoTreatment(
            for: damagedFieldCodedClip(), target: nil, index: longIndex, containerStart: 0)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments == [PlannedSegment(kind: .copy, range: 0..<100)])
    }

    /// Snapped cuts on a damaged copy-cut clip still plan copy-only: in 25 / out 49 are
    /// copy-valid marks on `longIndex` (exactly what `CopyCutSnapper` produces), the zone
    /// (frames 40–45) sits inside the kept range, and it copies verbatim regardless.
    @Test func fieldCodedDamagedClipWithSnappedCutsStaysCopyOnly() throws {
        let treatment = try ExportPlanner.videoTreatment(
            for: damagedFieldCodedClip(inPoint: 25, outPoint: 49), target: nil,
            index: longIndex, containerStart: 0)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments == [PlannedSegment(kind: .copy, range: 25..<50, outCutKeyframe: 50)])
    }

    /// The `.repair` purpose keeps the full pre-#96 behavior (the #54 regression pin):
    /// damage zones plan their repaired `.reEncode` segments and the copy-only invariant
    /// does not fire — those segments are exactly what `ClipDoctorEngine.fieldCodedRepair`
    /// collapses into the copy-head + MBAFF-tail plan (ADR-0022).
    @Test func repairPurposePlansTheDamageReencodeSegmentsOnAFieldCodedClip() throws {
        let zone = DamageZone(start: 1.6, end: 1.8, affectsVideo: true)
        let treatment = try ExportPlanner.videoTreatment(
            for: damagedFieldCodedClip(), target: nil, index: longIndex,
            containerStart: 0, purpose: .repair)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments == [
            PlannedSegment(kind: .copy, range: 0..<25, outCutKeyframe: 25),
            PlannedSegment(kind: .reEncode, range: 25..<50, damage: [zone]),
            PlannedSegment(kind: .copy, range: 50..<100),
        ])
    }

    /// The row's copied-% badge reads the same `.export` verdict (`copyShare` calls
    /// `videoTreatment` with the default purpose): a damaged copy-cut clip shows 100 %
    /// copied, consistent with the verbatim export it gets.
    @Test func copyShareOfADamagedFieldCodedClipIsAllCopy() throws {
        let share = try #require(ExportPlanner.copyShare(
            for: damagedFieldCodedClip(), target: nil, settings: OutputSettings(),
            index: longIndex, containerStart: 0))
        #expect(share.copiedFraction == 1.0)
    }

    /// `planItem` threads the copy-cut route onto the item so the engine can pick the
    /// field-coded execution recipe (slice 4): true only for a confirmed field-coded
    /// H.264 clip — progressive and unsupported-codec field-coded clips carry false.
    @Test func plannedItemCarriesTheFieldCodedRoute() throws {
        func item(for clip: Clip) throws -> ExportItem {
            try ExportPlanner.planItem(
                for: ExportPlanner.ClipInput(clip: clip,
                                             url: URL(fileURLWithPath: "/tmp/a.ts"),
                                             index: index, containerStart: 0,
                                             audioSources: [.stream(0)]),
                target: nil)
        }
        #expect(try item(for: fieldCodedClip()).fieldCoded)
        #expect(try !item(for: clip(video: video())).fieldCoded)
        #expect(try !item(for: fieldCodedClip(codec: "mpeg2video")).fieldCoded)
    }
}
