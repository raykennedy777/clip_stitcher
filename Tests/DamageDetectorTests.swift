import Testing
import Foundation
@testable import ClipStitcher

struct DamageDetectorTests {
    private func stamps(interval: Double, count: Int, from: Double = 0) -> [FrameIndexer.PacketStamp] {
        (0..<count).map {
            let t = from + Double($0) * interval
            return FrameIndexer.PacketStamp(pts: t, dts: t)
        }
    }

    private func video(_ packets: [FrameIndexer.PacketStamp]) -> FrameIndexer.StreamPackets {
        FrameIndexer.StreamPackets(streamIndex: 0, isVideo: true, packets: packets)
    }

    private func audio(_ packets: [FrameIndexer.PacketStamp], index: Int = 1) -> FrameIndexer.StreamPackets {
        FrameIndexer.StreamPackets(streamIndex: index, isVideo: false, packets: packets)
    }

    @Test func videoDtsGapIsAnAnomaly() {
        var packets = stamps(interval: 0.04, count: 100, from: 38.0)
        packets += stamps(interval: 0.04, count: 100, from: 38.0 + 100 * 0.04 + 0.84)
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.count == 1)
        #expect(found[0].isVideo)
        #expect(abs(found[0].start - 41.96) < 1e-9)
        #expect(abs(found[0].end - 42.84) < 1e-9)
    }

    @Test func timestamplessVideoPacketIsAnAnomaly() {
        var packets = stamps(interval: 0.04, count: 50)
        packets.append(FrameIndexer.PacketStamp(pts: nil, dts: nil))
        packets += stamps(interval: 0.04, count: 50, from: 50 * 0.04)
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found == [DamageDetector.Anomaly(start: 49 * 0.04, end: 49 * 0.04, isVideo: true)])
    }

    @Test func duplicateDtsBurstIsAnAnomaly() {
        var packets = stamps(interval: 0.02, count: 100)
        let t = 100 * 0.02
        packets.append(FrameIndexer.PacketStamp(pts: t, dts: t))
        packets.append(FrameIndexer.PacketStamp(pts: t + 0.001, dts: t + 0.001))
        packets += stamps(interval: 0.02, count: 100, from: t + 0.02)
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.count == 1 && found[0].isVideo)
    }

    @Test func audioPtsGapInAnyStreamIsAnAnomaly() {
        var damaged = stamps(interval: 0.024, count: 100)
        damaged += stamps(interval: 0.024, count: 100, from: 100 * 0.024 + 0.6)
        let found = DamageDetector.anomalies(streams: [
            audio(stamps(interval: 0.024, count: 205), index: 1),
            audio(damaged, index: 2),
        ])
        #expect(found.count == 1)
        #expect(!found[0].isVideo)
        #expect(abs(found[0].end - found[0].start - 0.624) < 1e-9)
    }

    @Test func cleanStreamsAndPtsOnlyQuirksProduceNoAnomalies() {
        var packets = stamps(interval: 0.04, count: 200)
        packets[50].pts = nil
        packets[120].pts = nil
        let found = DamageDetector.anomalies(streams: [
            video(packets), audio(stamps(interval: 0.024, count: 300)),
        ])
        #expect(found.isEmpty)
    }

    @Test func matroskaHeadReorderPlaceholdersAreNotAnomalies() {
        var packets: [FrameIndexer.PacketStamp] = [
            FrameIndexer.PacketStamp(pts: 0.0, dts: nil, keyframe: true),
            FrameIndexer.PacketStamp(pts: 0.16, dts: nil),
        ]
        packets += (0..<100).map {
            FrameIndexer.PacketStamp(pts: Double($0) * 0.04 + 0.08, dts: Double($0) * 0.04)
        }
        #expect(DamageDetector.anomalies(streams: [video(packets)]).isEmpty)
    }

    @Test func dtsPoorStreamsFallBackToPresentationGapsOnly() {
        var packets = (0..<100).map { FrameIndexer.PacketStamp(pts: Double($0) * 0.04, dts: nil) }
        packets += (0..<100).map { FrameIndexer.PacketStamp(pts: Double($0) * 0.04 + 4.6, dts: nil) }
        packets.append(FrameIndexer.PacketStamp(pts: 0.76, dts: nil))
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.count == 1)
        #expect(abs(found[0].start - 3.96) < 1e-9 && abs(found[0].end - 4.6) < 1e-9)
    }

    @Test func thinStreamsAreSkipped() {
        let found = DamageDetector.anomalies(streams: [
            video(stamps(interval: 0.04, count: 10)),
            audio(stamps(interval: 5.0, count: 4)),
        ])
        #expect(found.isEmpty)
    }

    @Test func nearbyAnomaliesMergeIntoOneCandidate() {
        let candidates = DamageDetector.clusterCandidates([
            .init(start: 16334.16, end: 16334.36, isVideo: false),
            .init(start: 16334.36, end: 16334.72, isVideo: true, needsDecodeConfirm: true),
            .init(start: 16672.08, end: 16672.90, isVideo: true, needsDecodeConfirm: true),
        ])
        #expect(candidates == [
            .init(start: 16334.16, end: 16334.72, hasVideoAnomaly: true,
                  hasOpaqueVideoAnomaly: false, hasAudioAnomaly: true),
            .init(start: 16672.08, end: 16672.90, hasVideoAnomaly: true,
                  hasOpaqueVideoAnomaly: false, hasAudioAnomaly: false),
        ])
    }

    @Test func longAnomalyRunsMergeIntoOneCandidate() {
        let anomalies = stride(from: 8132.35, to: 8171.0, by: 0.5).map {
            DamageDetector.Anomaly(start: $0, end: $0 + 0.4, isVideo: false)
        }
        let candidates = DamageDetector.clusterCandidates(anomalies)
        #expect(candidates.count == 1)
        #expect(abs(candidates[0].start - 8132.35) < 1e-9)
        #expect(candidates[0].end > 8170.0)
    }

    @Test func paffHeadToMbaffTailDoesNotFloodTheTailWithGaps() {
        var packets = stamps(interval: 0.02, count: 4000)
        packets += stamps(interval: 0.04, count: 400, from: 4000 * 0.02 + 0.04)
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.count <= 2, "tail flooded: \(found.count) anomalies")
    }

    @Test func aRealHoleInsideTheSlowerTailIsStillAGap() {
        var packets = stamps(interval: 0.02, count: 4000)
        var tail = stamps(interval: 0.04, count: 400, from: 4000 * 0.02 + 0.04)
        tail += stamps(interval: 0.04, count: 400, from: tail.last!.dts! + 0.84)
        packets += tail
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.contains { $0.isVideo && abs($0.end - $0.start - 0.84) < 1e-6 })
    }

    @Test func aDamageRegionCollapsingTheLocalMedianStaysCaughtViaGlobal() {
        var packets = stamps(interval: 0.04, count: 200)
        let t = 200 * 0.04
        for k in 0..<5 { packets.append(.init(pts: t + Double(k) * 0.001, dts: t + Double(k) * 0.001)) }
        packets += stamps(interval: 0.04, count: 200, from: t + 0.04)
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.contains { $0.isVideo })
    }

    @Test func sustainedAlternatingDropRegionYieldsACandidate() {
        var packets = stamps(interval: 0.04, count: 300, from: 0)
        packets += (0..<250).map {
            let t = 12.0 + Double($0) * 0.08
            return FrameIndexer.PacketStamp(pts: t, dts: t)
        }
        packets += stamps(interval: 0.04, count: 300, from: 12.0 + 249 * 0.08 + 0.04)
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.contains { $0.isVideo && $0.needsDecodeConfirm })
        let candidates = DamageDetector.clusterCandidates(found)
        #expect(candidates.contains { $0.hasVideoAnomaly && $0.start < 12.5 && $0.end > 31.0 })
    }

    @Test func sustainedSlowRegionRunningToEOFIsNotFlaggedAsAGap() {
        var packets = stamps(interval: 0.04, count: 400, from: 0)
        packets += (1...300).map {
            let t = 16.0 + Double($0) * 0.08
            return FrameIndexer.PacketStamp(pts: t, dts: t)
        }
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(!found.contains { $0.needsDecodeConfirm })
    }

    @Test func aLateResumeHoleWithinTheJudgedWindowIsCorroborated() {
        let interval = 0.04
        var frames = (0...250).map {
            DamageDetector.DecodedFrame(pts: Double($0) * interval, corrupt: false)
        }
        frames += (0..<20).map {
            DamageDetector.DecodedFrame(pts: 11.3 + Double($0) * interval, corrupt: false)
        }
        let candidate = DamageDetector.Candidate(start: 9.8, end: 10.0, hasVideoAnomaly: true)
        let span = DamageDetector.videoDamageSpan(
            frames: frames, window: (candidate.start - 1.0)...(candidate.end + 1.5),
            frameInterval: interval)
        #expect(span != nil)
    }

    @Test func gapOnlyVideoThatDecodesCleanIsNotVideoDamage() {
        let seam = DamageDetector.Candidate(start: 80.0, end: 96.0, hasVideoAnomaly: true,
                                            hasOpaqueVideoAnomaly: false, hasAudioAnomaly: false)
        #expect(DamageDetector.resolveZone(candidate: seam, span: nil,
                                           decodedFrameCount: 2000, containerStart: 0,
                                           frameInterval: 0.04) == nil)
    }

    @Test func gapVideoWithACompanionAudioGapDegradesToAnAudioZone() {
        let c = DamageDetector.Candidate(start: 80.0, end: 96.0, hasVideoAnomaly: true,
                                         hasOpaqueVideoAnomaly: false, hasAudioAnomaly: true)
        let zone = DamageDetector.resolveZone(candidate: c, span: nil,
                                              decodedFrameCount: 2000, containerStart: 0,
                                              frameInterval: 0.04)
        #expect(zone == DamageZone(start: 80.0, end: 96.0, affectsVideo: false))
    }

    @Test func opaqueVideoAnomalyStaysVideoDamageEvenWhenTheDecodeIsClean() {
        let dead = DamageDetector.Candidate(start: 8132.0, end: 8171.0, hasVideoAnomaly: true,
                                            hasOpaqueVideoAnomaly: true, hasAudioAnomaly: true)
        let zone = DamageDetector.resolveZone(candidate: dead, span: nil,
                                              decodedFrameCount: 1500, containerStart: 0,
                                              frameInterval: 0.04)
        #expect(zone?.affectsVideo == true)
    }

    @Test func aGapKeepsItsVideoZoneWhenTheConfirmDecodeProducedNothing() {
        let c = DamageDetector.Candidate(start: 80.0, end: 96.0, hasVideoAnomaly: true,
                                         hasOpaqueVideoAnomaly: false, hasAudioAnomaly: false)
        #expect(DamageDetector.resolveZone(candidate: c, span: nil,
                                           decodedFrameCount: 0, containerStart: 0,
                                           frameInterval: 0.04)?.affectsVideo == true)
    }

    @Test func decodeCorroboratedGapIsStillVideoDamage() {
        let c = DamageDetector.Candidate(start: 41.96, end: 42.84, hasVideoAnomaly: true,
                                         hasOpaqueVideoAnomaly: false, hasAudioAnomaly: false)
        let zone = DamageDetector.resolveZone(candidate: c, span: (start: 41.9, end: 42.9),
                                              decodedFrameCount: 200, containerStart: 0,
                                              frameInterval: 0.04)
        #expect(zone?.affectsVideo == true)
        #expect(zone?.start == 41.9 && zone?.end == 42.9)
    }

    @Test func truncatedPictureOnlyClusterWidensToOneFrameNotZeroWidth() {
        let c = DamageDetector.Candidate(start: 100.0, end: 100.0, hasVideoAnomaly: true,
                                         hasOpaqueVideoAnomaly: true, hasAudioAnomaly: false)
        let zone = DamageDetector.resolveZone(candidate: c, span: nil,
                                              decodedFrameCount: 500, containerStart: 0,
                                              frameInterval: 0.04)
        #expect(zone?.affectsVideo == true)
        #expect(zone?.start == 100.0)
        #expect(abs((zone?.end ?? 0) - 100.04) < 1e-9)
    }

    @Test func nonZeroWidthLeavesRealZonesUntouchedButWidensCollapsedOnes() {
        let wide = DamageZone(start: 10.0, end: 12.0, affectsVideo: true)
        #expect(DamageDetector.nonZeroWidth(wide, frameInterval: 0.04) == wide)

        let collapsed = DamageZone(start: 5.0, end: 5.0, affectsVideo: true)
        let widened = DamageDetector.nonZeroWidth(collapsed, frameInterval: 0.04)
        #expect(widened.start == 5.0 && abs(widened.end - 5.04) < 1e-9)

        let audio = DamageDetector.nonZeroWidth(DamageZone(start: 1.0, end: 1.0, affectsVideo: false),
                                                frameInterval: 0.02)
        #expect(audio.affectsVideo == false && audio.end > audio.start)
    }

    @Test func eofTruncatedFinalFrameYieldsAOneFrameZone() throws {
        let interval = 0.04
        let frames = (0..<50).map {
            DamageDetector.DecodedFrame(pts: 100.0 + Double($0) * interval, corrupt: false)
        }
        let lastDecoded = frames.last!.pts
        let lastPts = lastDecoded + interval
        let zone = DamageDetector.eofZoneFromDecode(
            frames: frames, lastPts: lastPts, seekPts: 100.0,
            localInterval: interval, containerStart: 0)
        let z = try #require(zone)
        #expect(z.affectsVideo)
        #expect(z.end - z.start >= interval - 1e-9)
        #expect(z.end >= lastPts - 1e-9)
    }

    @Test func eofCleanTailYieldsNoZone() {
        let interval = 0.04
        let frames = (0..<50).map {
            DamageDetector.DecodedFrame(pts: 100.0 + Double($0) * interval, corrupt: false)
        }
        #expect(DamageDetector.eofZoneFromDecode(
            frames: frames, lastPts: frames.last!.pts, seekPts: 100.0,
            localInterval: interval, containerStart: 0) == nil)
    }

    @Test func parseConfirmDecodeFlagsTheFrameAfterACorruptReport() {
        let stderr = """
        [vist#0:0/h264 @ 0x1] [dec:h264 @ 0x2] corrupt decoded frame
        [Parsed_showinfo_0 @ 0x3] n:  22 pts:  45056 pts_time:0.88    duration:2048
        [Parsed_showinfo_0 @ 0x3] n:  23 pts:  47104 pts_time:0.92    duration:2048
        [aist#0:1/mp2 @ 0x4] [dec:mp2 @ 0x5] Error submitting packet to decoder: Invalid data found
        [Parsed_showinfo_0 @ 0x3] n:  24 pts:  49152 pts_time:0.96    duration:2048
        """
        #expect(DamageDetector.parseConfirmDecode(stderr: stderr) == [
            .init(pts: 0.88, corrupt: true),
            .init(pts: 0.92, corrupt: false),
            .init(pts: 0.96, corrupt: true),
        ])
    }

    @Test func corruptFramesAndHolesUnionIntoOneSpan() {
        let frames: [DamageDetector.DecodedFrame] = (0...22).map {
            .init(pts: Double($0) * 0.04, corrupt: $0 == 22)
        } + [.init(pts: 1.56, corrupt: false), .init(pts: 1.60, corrupt: false)]
        let span = DamageDetector.videoDamageSpan(
            frames: frames, window: 0.5...2.0, frameInterval: 0.04)
        #expect(span != nil)
        #expect(abs(span!.start - 0.86) < 1e-9)
        #expect(abs(span!.end - 1.54) < 1e-9)
    }

    @Test func cleanDecodeYieldsNoSpan() {
        let frames = (0..<100).map {
            DamageDetector.DecodedFrame(pts: Double($0) * 0.04, corrupt: false)
        }
        #expect(DamageDetector.videoDamageSpan(
            frames: frames, window: 0.0...4.0, frameInterval: 0.04) == nil)
    }

    @Test func damageOutsideTheWindowIsIgnored() {
        let frames: [DamageDetector.DecodedFrame] = [
            .init(pts: 0.0, corrupt: true),
            .init(pts: 0.04, corrupt: false),
            .init(pts: 0.08, corrupt: false),
        ] + (3..<80).map { .init(pts: Double($0) * 0.04, corrupt: false) }
        #expect(DamageDetector.videoDamageSpan(
            frames: frames, window: 1.0...3.0, frameInterval: 0.04) == nil)
    }

    @Test func marginIntervalIgnoresTheDamagedSpansOwnTiming() {
        let candidate = DamageDetector.Candidate(start: 10.0, end: 14.0, hasVideoAnomaly: true)
        var frames = (0..<50).map { DamageDetector.DecodedFrame(pts: 8.0 + Double($0) * 0.04, corrupt: false) }
        frames += (0..<100).map { .init(pts: 10.0 + Double($0) * 0.02, corrupt: false) }
        frames += (0..<50).map { .init(pts: 14.5 + Double($0) * 0.04, corrupt: false) }
        let local = DamageDetector.marginInterval(frames: frames, candidate: candidate)
        #expect(local != nil && abs(local! - 0.04) < 1e-9)
    }

    @Test func marginIntervalIsNilOnThinMargins() {
        let candidate = DamageDetector.Candidate(start: 0.0, end: 100.0, hasVideoAnomaly: true)
        let frames = (0..<50).map { DamageDetector.DecodedFrame(pts: Double($0) * 0.04, corrupt: false) }
        #expect(DamageDetector.marginInterval(frames: frames, candidate: candidate) == nil)
    }

    @Test func parseAllStreamsGroupsByStreamAndBuildsTheSameIndex() {
        let csv = """
        audio,1,0.540000,0.540000,K__,
        video,0,0.580000,0.500000,K__,
        video,0,0.540000,0.540000,___,
        audio,1,0.564000,0.564000,K__,
        video,0,N/A,0.580000,___,
        data,2,1.000000,1.000000,K__,
        """
        let scan = FrameIndexer.parseAllStreams(csv: csv)
        #expect(scan.streams.count == 2)
        #expect(scan.streams[0].streamIndex == 1 && !scan.streams[0].isVideo)
        #expect(scan.streams[1].streamIndex == 0 && scan.streams[1].isVideo)
        #expect(scan.streams[1].packets.count == 3)
        #expect(scan.index.pts == [0.54, 0.58, 0.58])
        #expect(scan.index.keyframeFlags == [false, true, false])
        let direct = FrameIndexer.parseIndex(csv: """
        0.580000,0.500000,K__,
        0.540000,0.540000,___,
        N/A,0.580000,___,
        """)
        #expect(scan.index.pts == direct.pts)
        #expect(scan.index.dts == direct.dts)
        #expect(scan.index.keyframeFlags == direct.keyframeFlags)
    }

    @Test func parseAllStreamsKeepsTimestamplessPackets() {
        let csv = """
        video,0,1.000000,1.000000,K__
        video,0,N/A,N/A,___
        video,0,1.040000,1.040000,___
        """
        let scan = FrameIndexer.parseAllStreams(csv: csv)
        #expect(scan.streams[0].packets.count == 3)
        #expect(scan.streams[0].packets[1] == FrameIndexer.PacketStamp(pts: nil, dts: nil, keyframe: false))
        #expect(scan.index.count == 2)
    }

    @Test func damageLineTextShowsCountAndClipTimes() {
        #expect(ClipRowView.damageLineText(zones: nil) == nil)
        #expect(ClipRowView.damageLineText(zones: []) == nil)
        #expect(ClipRowView.damageLineText(zones: [
            DamageZone(start: 1354.68, end: 1355.0, affectsVideo: true),
        ]) == "Damage zone at 22:34")
        #expect(ClipRowView.damageLineText(zones: [
            DamageZone(start: 1354.68, end: 1355.0, affectsVideo: true),
            DamageZone(start: 4714.22, end: 4714.9, affectsVideo: true),
        ]) == "2 damage zones at 22:34, 1:18:34")
        let many = (1...8).map { DamageZone(start: Double($0) * 100, end: Double($0) * 100 + 1, affectsVideo: false) }
        #expect(ClipRowView.damageLineText(zones: many) == "8 damage zones at 1:40, 3:20, 5:00, 6:40, 8:20, 10:00, …")
    }
}
