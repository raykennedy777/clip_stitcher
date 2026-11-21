import Testing
import Foundation
@testable import ClipStitcher

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

    private let index = FrameIndex(
        pts: [0.0, 0.04, 0.08, 0.12, 0.16, 0.20, 0.24, 0.28],
        keyframeFlags: [true, false, false, false, true, false, false, false])

    @Test func matchingClipIsSmartRendered() throws {
        let target = clip(video: video())
        let treatment = try ExportPlanner.videoTreatment(for: clip(video: video()),
                                                         target: target, index: index)
        guard case .smartRender(let segments, let encoder) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments == [PlannedSegment(kind: .copy, range: 0..<8)])
        #expect(!encoder.isEmpty)
    }

    @Test func theSmartRenderEncoderCarriesRateControlFromTheProbedBitrate() throws {
        func encoder(_ v: VideoProperties) throws -> [String] {
            guard case .smartRender(_, let encoder) = try ExportPlanner.videoTreatment(
                for: clip(video: v), target: nil, index: index) else {
                Issue.record("expected smart render"); return []
            }
            return encoder
        }
        var hevc = video(codec: "hevc"); hevc.bitrate = 12_000_000
        #expect(try encoder(hevc).suffix(2) == ["-crf", "18"])
        var mpeg2 = video(codec: "mpeg2video"); mpeg2.bitrate = 4_000_000
        #expect(try encoder(mpeg2).suffix(6)
            == ["-b:v", "5000000", "-maxrate", "7500000", "-bufsize", "10000000"])
        #expect(try encoder(video(codec: "mpeg2video")).suffix(2) == ["-q:v", "2"])
    }

    @Test func nonMatchingClipIsConformed() throws {
        let target = clip(video: video(codec: "h264"))
        let source = clip(video: video(codec: "mpeg2video"))
        let treatment = try ExportPlanner.videoTreatment(for: source, target: target, index: index)
        #expect(treatment == .conform(ConformEngine.VideoConform(
            sourceVideo: video(codec: "mpeg2video"), targetVideo: video(codec: "h264"))))
    }

    @Test func noTargetClipMeansSmartRender() throws {
        let treatment = try ExportPlanner.videoTreatment(for: clip(video: video(codec: "hevc")),
                                                         target: nil, index: index)
        guard case .smartRender = treatment else {
            Issue.record("expected smart render")
            return
        }
    }

    @Test func clipWithoutVideoRefusesToPlan() {
        #expect(throws: ExportError.self) {
            try ExportPlanner.videoTreatment(for: clip(video: nil),
                                             target: clip(video: video()), index: index)
        }
    }

    @Test func collapsedKeptRangeThrowsInvalidPlan() {
        let c = clip(video: video(), inPoint: 5, outPoint: 2)
        #expect(throws: ExportError.self) {
            try ExportPlanner.videoTreatment(for: c, target: nil, index: index)
        }
    }

    @Test func smartRenderedItemCarriesPlanWindowAndSources() throws {
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
        #expect(abs((item.audioEnd ?? 0) - 0.28) < 1e-9)
        #expect(abs((item.audioDuration ?? 0) - 0.20) < 1e-9)
        #expect(item.audioSources == [.stream(0), nil])
        #expect(!item.encoder.isEmpty)
    }

    @Test func conformedItemCarriesTheTargetCodecAndNoSegments() throws {
        let input = ExportPlanner.ClipInput(
            clip: clip(video: video(codec: "mpeg2video")),
            url: URL(fileURLWithPath: "/tmp/b.mpg"), index: index,
            containerStart: 0.24, audioSources: [.stream(0)])
        let item = try ExportPlanner.planItem(for: input, target: clip(video: video(codec: "h264")))
        #expect(item.conform != nil)
        #expect(item.segments.isEmpty)
        #expect(item.codec == "h264")
        #expect(item.audioStart == nil)
        #expect(item.audioEnd == nil)
    }

    @Test func inOutPastTheIndexEndThrowsInsteadOfTrapping() {
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

    @Test func frameDurationParsesARationalRate() {
        #expect(ExportPlanner.frameDuration("25/1") == 0.04)
        #expect(ExportPlanner.frameDuration("30000/1001") == 1001.0 / 30000.0)
        #expect(ExportPlanner.frameDuration(nil) == nil)
        #expect(ExportPlanner.frameDuration("") == nil)
        #expect(ExportPlanner.frameDuration("25") == nil)
        #expect(ExportPlanner.frameDuration("0/1") == nil)
    }

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

    @Test func copyShareIsZeroWhenNoCopySafePointExists() throws {
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

    @Test func copyShareOfAConformedClipIsZeroOverItsKeptWindow() throws {
        let share = try #require(ExportPlanner.copyShare(
            for: clip(video: video(codec: "mpeg2video")),
            target: clip(video: video(codec: "h264")), settings: OutputSettings(), index: index))
        #expect(share.copiedSeconds == 0)
        #expect(abs(share.totalSeconds - 0.32) < 1e-9)
    }

    @Test func copyShareUnderCutOnlyIgnoresTheTarget() throws {
        let share = try #require(ExportPlanner.copyShare(
            for: clip(video: video(codec: "mpeg2video")),
            target: clip(video: video(codec: "h264")),
            settings: settings(mode: .separate, rendering: .cutOnly), index: index))
        #expect(share.copiedFraction == 1.0)
    }

    private let longIndex = FrameIndex(
        pts: (0..<100).map { Double($0) * 0.04 },
        keyframeFlags: (0..<100).map { $0 % 25 == 0 })

    private func damagedClip(zones: [DamageZone]) -> Clip {
        var c = clip(video: video())
        c.damageZones = zones
        return c
    }

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

    @Test func zoneMappingHonorsTheContainerStart() throws {
        let shifted = FrameIndex(
            pts: (0..<100).map { 1.44 + Double($0) * 0.04 },
            keyframeFlags: (0..<100).map { $0 % 25 == 0 })
        let zone = DamageZone(start: 1.6, end: 1.8, affectsVideo: true)
        let treatment = try ExportPlanner.videoTreatment(
            for: damagedClip(zones: [zone]), target: nil, index: shifted, containerStart: 1.44)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments.contains(PlannedSegment(kind: .reEncode, range: 25..<50, damage: [zone])))
    }

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
        #expect(item.sourceDamaged)
    }

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

    @Test func repairReportListsVideoZonesInTheKeptWindow() {
        let zones = [
            DamageZone(start: 95.5, end: 96.0, affectsVideo: true),
            DamageZone(start: 4774.84, end: 4775.5, affectsVideo: true),
            DamageZone(start: 200.0, end: 200.5, affectsVideo: false),
        ]
        #expect(ExportPlanner.repairReport(clipName: "match.ts", zones: zones,
                                           windowStart: nil, windowEnd: nil)
            == "Repaired 2 damage zones in “match.ts” at 1:35, 1:19:34.")
        #expect(ExportPlanner.repairReport(clipName: "match.ts", zones: [zones[0]],
                                           windowStart: nil, windowEnd: nil)
            == "Repaired a damage zone in “match.ts” at 1:35.")
    }

    @Test func repairReportNamesATruncatedEnding() {
        let ending = [DamageZone(start: 599.6, end: 600.0, affectsVideo: true)]
        #expect(ExportPlanner.repairReport(clipName: "live.ts", zones: ending,
                                           windowStart: nil, windowEnd: 600.0, trimEnd: 599.6)
            == "Repaired a truncated ending in “live.ts”.")
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

    @Test func repairReportMatchesTheEngineTrimDecision() {
        let ending = [DamageZone(start: 599.6, end: 600.0, affectsVideo: true)]
        #expect(ExportPlanner.repairReport(clipName: "c", zones: ending,
                                           windowStart: nil, windowEnd: 600.0, trimEnd: nil)
            == "Repaired a damage zone in “c” at 9:59.")
        #expect(ExportPlanner.repairReport(clipName: "c", zones: ending,
                                           windowStart: nil, windowEnd: 600.0, trimEnd: 599.6)
            == "Repaired a truncated ending in “c”.")
    }

    @Test func repairReportNamesATruncatedEndingWithNilDuration() {
        let ending = [DamageZone(start: 4774.84, end: 4775.5, affectsVideo: true)]
        #expect(ExportPlanner.repairReport(clipName: "c", zones: ending,
                                           windowStart: nil, windowEnd: nil, trimEnd: 4774.84)
            == "Repaired a truncated ending in “c”.")
    }

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
        #expect(ExportPlanner.repairReport(clipName: "c", zones: zones,
                                           windowStart: 400, windowEnd: 600)
            == "Repaired a damage zone in “c” at 8:20.")
        #expect(ExportPlanner.repairReport(clipName: "c", zones: zones,
                                           windowStart: 1000, windowEnd: nil) == nil)
        #expect(ExportPlanner.repairReport(clipName: "c", zones: nil,
                                           windowStart: nil, windowEnd: nil) == nil)
        #expect(ExportPlanner.repairReport(clipName: "c", zones: [],
                                           windowStart: nil, windowEnd: nil) == nil)
    }

    @Test func truncatedEndingTrimGatesOnFileEndAndAOneIntervalMargin() {
        let eof = [DamageZone(start: 0.28, end: 0.32, affectsVideo: true)]
        #expect(ExportPlanner.truncatedEndingTrim(
            zones: eof, windowStart: nil, fileEnd: 0.32,
            reachesFileEnd: true, frameInterval: 0.04) == 0.28)
        #expect(ExportPlanner.truncatedEndingTrim(
            zones: eof, windowStart: nil, fileEnd: 0.32,
            reachesFileEnd: false, frameInterval: 0.04) == nil)
        #expect(ExportPlanner.truncatedEndingTrim(
            zones: [DamageZone(start: 0.08, end: 0.12, affectsVideo: true)],
            windowStart: nil, fileEnd: 0.32, reachesFileEnd: true, frameInterval: 0.04) == nil)
        #expect(ExportPlanner.truncatedEndingTrim(
            zones: [DamageZone(start: 0.10, end: 0.32, affectsVideo: true)],
            windowStart: 0.10, fileEnd: 0.32, reachesFileEnd: true, frameInterval: 0.04) == nil)
        #expect(ExportPlanner.truncatedEndingTrim(
            zones: [DamageZone(start: 0.28, end: 0.32, affectsVideo: false)],
            windowStart: nil, fileEnd: 0.32, reachesFileEnd: true, frameInterval: 0.04) == nil)
    }

    @Test func truncatedEndingTrimForClipReachesFileEndOnlyAtEOF() {
        let eof = [DamageZone(start: 0.28, end: 0.32, affectsVideo: true)]
        var openOut = clip(video: video()); openOut.damageZones = eof
        #expect(ExportPlanner.truncatedEndingTrim(
            for: openOut, index: index, containerStart: 0, windowStart: nil) == 0.28)
        var lastFrameOut = clip(video: video(), outPoint: 7); lastFrameOut.damageZones = eof
        #expect(ExportPlanner.truncatedEndingTrim(
            for: lastFrameOut, index: index, containerStart: 0, windowStart: nil) == 0.28)
        var interiorOut = clip(video: video(), outPoint: 3); interiorOut.damageZones = eof
        #expect(ExportPlanner.truncatedEndingTrim(
            for: interiorOut, index: index, containerStart: 0, windowStart: nil) == nil)
    }

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

    @Test func reencodeWarningFiresOnlyAboveTheDominanceThreshold() {
        let dominated = [ExportPlanner.CopyShare(copiedSeconds: 0, totalSeconds: 28)]
        #expect(ExportPlanner.reencodeDominanceWarning(shares: dominated)
            == "~28 s of 28 s will be re-encoded — little of this export can be stream-copied untouched.")
        let slivers = [ExportPlanner.CopyShare(copiedSeconds: 26, totalSeconds: 28)]
        #expect(ExportPlanner.reencodeDominanceWarning(shares: slivers) == nil)
        let half = [ExportPlanner.CopyShare(copiedSeconds: 14, totalSeconds: 28)]
        #expect(ExportPlanner.reencodeDominanceWarning(shares: half) == nil)
        #expect(ExportPlanner.reencodeDominanceWarning(shares: []) == nil)
    }

    private func fieldCodedClip(codec: String = "h264",
                                inPoint: Int? = nil, outPoint: Int? = nil) -> Clip {
        var c = clip(video: video(codec: codec), inPoint: inPoint, outPoint: outPoint)
        c.fieldCoded = true
        return c
    }

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

    @Test func fieldCodedWholeClipKeepStaysAPureCopy() throws {
        let treatment = try ExportPlanner.videoTreatment(
            for: fieldCodedClip(), target: nil, index: index)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments == [PlannedSegment(kind: .copy, range: 0..<8)])
    }

    private func damagedFieldCodedClip(inPoint: Int? = nil, outPoint: Int? = nil) -> Clip {
        var c = fieldCodedClip(inPoint: inPoint, outPoint: outPoint)
        c.damageZones = [DamageZone(start: 1.6, end: 1.8, affectsVideo: true)]
        return c
    }

    @Test func fieldCodedDamagedClipExportsItsDamageVerbatim() throws {
        let treatment = try ExportPlanner.videoTreatment(
            for: damagedFieldCodedClip(), target: nil, index: longIndex, containerStart: 0)
        guard case .smartRender(let segments, _) = treatment else {
            Issue.record("expected smart render")
            return
        }
        #expect(segments == [PlannedSegment(kind: .copy, range: 0..<100)])
    }

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

    @Test func copyShareOfADamagedFieldCodedClipIsAllCopy() throws {
        let share = try #require(ExportPlanner.copyShare(
            for: damagedFieldCodedClip(), target: nil, settings: OutputSettings(),
            index: longIndex, containerStart: 0))
        #expect(share.copiedFraction == 1.0)
    }

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

    @Test func mkvJoinWarnsWhenTheFirstClipsCopiesAreShallowerThanALaterClips() {
        var settings = OutputSettings(); settings.container = .mkv; settings.mode = .connect
        let shallowFirst = copyingItem(name: "Broadcast", depth: 1)
        let deepLater = copyingItem(name: "Web feed", depth: 2)
        let note = ExportPlanner.reorderDepthWarning(items: [shallowFirst, deepLater], settings: settings)
        #expect(note?.contains("Web feed") == true)
        #expect(note?.contains("Broadcast") == true)

        #expect(ExportPlanner.reorderDepthWarning(items: [deepLater, shallowFirst],
                                                  settings: settings) == nil)
        #expect(ExportPlanner.reorderDepthWarning(items: [deepLater, deepLater],
                                                  settings: settings) == nil)
        #expect(ExportPlanner.reorderDepthWarning(items: [shallowFirst], settings: settings) == nil)
    }

    @Test func onlyMkvConnectJoinsCanHitTheReorderDepthConstraint() {
        let items = [copyingItem(name: "Broadcast", depth: 1), copyingItem(name: "Web feed", depth: 2)]
        for container in [Container.ts, .mp4] {
            var settings = OutputSettings(); settings.container = container; settings.mode = .connect
            #expect(ExportPlanner.reorderDepthWarning(items: items, settings: settings) == nil)
        }
        var separate = OutputSettings(); separate.container = .mkv; separate.mode = .separate
        #expect(ExportPlanner.reorderDepthWarning(items: items, settings: separate) == nil)
        var audioOnly = OutputSettings(); audioOnly.container = .mkv
        audioOnly.mode = .connect; audioOnly.type = .audioOnly
        #expect(ExportPlanner.reorderDepthWarning(items: items, settings: audioOnly) == nil)
    }

    private func copyingItem(name: String, depth: Int) -> ExportItem {
        ExportItem(source: URL(fileURLWithPath: "/tmp/\(name).mkv"), displayName: name,
                   segments: [PlannedSegment(kind: .copy, range: 0..<4)],
                   sourceReorderDepth: depth)
    }

    private var openGopIndex: FrameIndex {
        var dts = (0..<100).map { Double($0) * 0.04 }
        dts[50] = 1.95
        dts[49] = 1.97
        return FrameIndex(pts: (0..<100).map { Double($0) * 0.04 }, dts: dts,
                          keyframeFlags: (0..<100).map { $0 == 0 || $0 == 50 })
    }

    private func segments(_ treatment: ExportPlanner.VideoTreatment) -> [PlannedSegment]? {
        guard case .smartRender(let segments, _) = treatment else { return nil }
        return segments
    }

    @Test func anHevcInPointSplicesAtTheNextKeyframe() throws {
        let hevc = clip(video: video(codec: "hevc"), inPoint: 10)
        #expect(segments(try ExportPlanner.videoTreatment(for: hevc, target: nil, index: openGopIndex))
                == [PlannedSegment(kind: .reEncode, range: 10..<50),
                    PlannedSegment(kind: .copy, range: 50..<100, droppedLeadingPictures: 1)])
    }

    @Test func otherCodecsAndDamagedSourcesKeepTheCopySafeRule() throws {
        let strict = [PlannedSegment(kind: .reEncode, range: 10..<100)]
        for codec in ["h264", "mpeg2video"] {
            #expect(segments(try ExportPlanner.videoTreatment(
                for: clip(video: video(codec: codec), inPoint: 10), target: nil, index: openGopIndex))
                    == strict)
        }
        var damaged = clip(video: video(codec: "hevc"), inPoint: 10)
        damaged.damageZones = [DamageZone(start: 3.0, end: 3.1, affectsVideo: false)]
        #expect(!ExportPlanner.allowsOpenInPoint(damaged, copyCutRoute: false))
        var clean = clip(video: video(codec: "hevc"), inPoint: 10)
        clean.damageZones = []
        #expect(ExportPlanner.allowsOpenInPoint(clean, copyCutRoute: false))
        #expect(!ExportPlanner.allowsOpenInPoint(clean, copyCutRoute: true))
    }

    @Test func aSplicedItemCarriesItsCopySafeFallback() throws {
        func item(_ codec: String) throws -> ExportItem {
            try ExportPlanner.planItem(
                for: ExportPlanner.ClipInput(clip: clip(video: video(codec: codec), inPoint: 10),
                                             url: URL(fileURLWithPath: "/media/a.mkv"),
                                             index: openGopIndex, containerStart: 0,
                                             audioSources: []),
                target: nil)
        }
        #expect(try item("hevc").fallbackSegments == [PlannedSegment(kind: .reEncode, range: 10..<100)])
        #expect(try item("h264").fallbackSegments == nil)
    }
}
