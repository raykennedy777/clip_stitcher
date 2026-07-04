import Testing
import Foundation
@testable import ClipStitcher

/// The damage detector's pure stages (issue #45): demux anomaly extraction,
/// clustering, confirm-decode parsing, and zone span math. The shapes and numbers
/// mirror the real corrupted captures (documented on issues #43/#45) so the verdicts
/// can't drift from the empirically established ground truth.
struct DamageDetectorTests {

    /// `count` packets at `interval`, both stamps filled, starting at `from`.
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

    // MARK: anomaly pass

    @Test func videoDtsGapIsAnAnomaly() {
        // A dropout hole: packets resume 0.84 s after 41.9 on a 0.04 cadence (the
        // synthetic mpeg2 fixture's zone-1 numbers).
        var packets = stamps(interval: 0.04, count: 100, from: 38.0)
        packets += stamps(interval: 0.04, count: 100, from: 38.0 + 100 * 0.04 + 0.84)
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.count == 1)
        #expect(found[0].isVideo)
        #expect(abs(found[0].start - 41.96) < 1e-9)
        #expect(abs(found[0].end - 42.84) < 1e-9)
    }

    @Test func timestamplessVideoPacketIsAnAnomaly() {
        // The real capture's truncated pictures: N/A pts and dts. Timed at the last
        // seen stamp.
        var packets = stamps(interval: 0.04, count: 50)
        packets.append(FrameIndexer.PacketStamp(pts: nil, dts: nil))
        packets += stamps(interval: 0.04, count: 50, from: 50 * 0.04)
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found == [DamageDetector.Anomaly(start: 49 * 0.04, end: 49 * 0.04, isVideo: true)])
    }

    @Test func duplicateDtsBurstIsAnAnomaly() {
        // Garbled PES headers: the demuxer synthesizes micro-increment dts (the real
        // 1842 capture's 39 s zone signature).
        var packets = stamps(interval: 0.02, count: 100)
        let t = 100 * 0.02
        packets.append(FrameIndexer.PacketStamp(pts: t, dts: t))
        packets.append(FrameIndexer.PacketStamp(pts: t + 0.001, dts: t + 0.001))
        packets += stamps(interval: 0.02, count: 100, from: t + 0.02)
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.count == 1 && found[0].isVideo)
    }

    @Test func audioPtsGapInAnyStreamIsAnAnomaly() {
        // The second audio stream gaps; the first is clean. On the real capture the
        // audio gap is often the *only* trace of a video damage event.
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
        // The broadcast capture's benign shape: dts fully continuous, some packets missing
        // *pts only* (refilled from dts by the index — ADR-0006). Zero anomalies:
        // the empirical full-file scan of the real capture found exactly none.
        var packets = stamps(interval: 0.04, count: 200)
        packets[50].pts = nil
        packets[120].pts = nil
        let found = DamageDetector.anomalies(streams: [
            video(packets), audio(stamps(interval: 0.024, count: 300)),
        ])
        #expect(found.isEmpty)
    }

    @Test func matroskaHeadReorderPlaceholdersAreNotAnomalies() {
        // Matroska stores no dts: ffprobe leaves the first reorder-depth packets
        // dts-less (pts present) and synthesizes the rest. The clean H.264/HEVC
        // fixtures start exactly like this — it must read as silence, not as a
        // gap+dup pair at the file head.
        var packets: [FrameIndexer.PacketStamp] = [
            FrameIndexer.PacketStamp(pts: 0.0, dts: nil, keyframe: true),
            FrameIndexer.PacketStamp(pts: 0.16, dts: nil),
        ]
        // decode order continues: dts from 0, pts reordered around it
        packets += (0..<100).map {
            FrameIndexer.PacketStamp(pts: Double($0) * 0.04 + 0.08, dts: Double($0) * 0.04)
        }
        #expect(DamageDetector.anomalies(streams: [video(packets)]).isEmpty)
    }

    @Test func dtsPoorStreamsFallBackToPresentationGapsOnly() {
        // A container with (almost) no dts at all: gaps still read off sorted pts,
        // but the duplicate rule stays off — sorted pts legitimately duplicates on
        // timestamp-dirty sources.
        var packets = (0..<100).map { FrameIndexer.PacketStamp(pts: Double($0) * 0.04, dts: nil) }
        packets += (0..<100).map { FrameIndexer.PacketStamp(pts: Double($0) * 0.04 + 4.6, dts: nil) }
        packets.append(FrameIndexer.PacketStamp(pts: 0.76, dts: nil))   // a benign duplicate pts
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.count == 1)
        #expect(abs(found[0].start - 3.96) < 1e-9 && abs(found[0].end - 4.6) < 1e-9)
    }

    @Test func thinStreamsAreSkipped() {
        // Below the cadence threshold there is nothing to break.
        let found = DamageDetector.anomalies(streams: [
            video(stamps(interval: 0.04, count: 10)),
            audio(stamps(interval: 5.0, count: 4)),
        ])
        #expect(found.isEmpty)
    }

    // MARK: clustering

    @Test func nearbyAnomaliesMergeIntoOneCandidate() {
        // The real 1844 capture's double-hit events (two holes 0.4 s apart) and their
        // companion audio gaps merge to one candidate; an event 200 s away stays its own.
        // The video holes are gaps (decode-confirmable); the first cluster also carries an
        // audio gap — both facts ride through clustering for the gap-vs-opaque authority rule.
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
        // The 39 s dead zone: hundreds of audio gaps within 2 s of each other → one
        // candidate spanning the whole run.
        let anomalies = stride(from: 8132.35, to: 8171.0, by: 0.5).map {
            DamageDetector.Anomaly(start: $0, end: $0 + 0.4, isVideo: false)
        }
        let candidates = DamageDetector.clusterCandidates(anomalies)
        #expect(candidates.count == 1)
        #expect(abs(candidates[0].start - 8132.35) < 1e-9)
        #expect(candidates[0].end > 8170.0)
    }

    // MARK: gap-vs-opaque authority (issue: Clip Doctor output re-flags its own seam)

    @Test func paffHeadToMbaffTailDoesNotFloodTheTailWithGaps() {
        // Clip Doctor's field-coded output: a PAFF copy-head (two field packets per frame,
        // 0.02 s apart) spliced onto an MBAFF re-encoded tail (one packet per frame, 0.04 s).
        // The head dominates the global median (0.02 s), so every 0.04 s tail step clears the
        // bare 1.8× bar — without the local-cadence gate this floods ~400 gap anomalies into
        // one file-long candidate and a multi-minute confirm decode. The gate reads the tail's
        // own cadence and leaves at most a couple of anomalies at the transition.
        var packets = stamps(interval: 0.02, count: 4000)              // PAFF head, 80 s
        packets += stamps(interval: 0.04, count: 400, from: 4000 * 0.02 + 0.04)  // MBAFF tail, 16 s
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.count <= 2, "tail flooded: \(found.count) anomalies")
    }

    @Test func aRealHoleInsideTheSlowerTailIsStillAGap() {
        // The gate must not blind the tail to genuine damage: a real 0.84 s hole among the
        // 0.04 s MBAFF tail steps still beats the local cadence and flags.
        var packets = stamps(interval: 0.02, count: 4000)              // PAFF head
        var tail = stamps(interval: 0.04, count: 400, from: 4000 * 0.02 + 0.04)
        tail += stamps(interval: 0.04, count: 400, from: tail.last!.dts! + 0.84)  // 0.84 s hole
        packets += tail
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.contains { $0.isVideo && abs($0.end - $0.start - 0.84) < 1e-6 })
    }

    @Test func aDamageRegionCollapsingTheLocalMedianStaysCaughtViaGlobal() {
        // A single-cadence (0.04) stream whose dup bursts would pull a *local* median far below
        // the global one — `max(global, local)` must fall back to the global bar so the path is
        // unchanged from before. The dup burst is still detected (duplicate rule, global median).
        var packets = stamps(interval: 0.04, count: 200)
        let t = 200 * 0.04
        for k in 0..<5 { packets.append(.init(pts: t + Double(k) * 0.001, dts: t + Double(k) * 0.001)) }
        packets += stamps(interval: 0.04, count: 200, from: t + 0.04)
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.contains { $0.isVideo })
    }

    // MARK: sustained slow-region detection (issue #80: local-median inflation)

    @Test func sustainedAlternatingDropRegionYieldsACandidate() {
        // Defect 1 (#80): a 20 s region where every other frame is dropped runs at 2× the baseline
        // cadence (0.08 vs 0.04). It fills its own 201-delta local-median window, so `max(global,
        // local)` rises above the very gaps that are the damage and the per-step rule sees nothing.
        // A bounded slow region that *returns* to the baseline cadence is emitted as one gap
        // candidate for the decode to confirm — the requirement is ≥ 1 candidate.
        var packets = stamps(interval: 0.04, count: 300, from: 0)              // baseline 12 s
        packets += (0..<250).map {                                            // 20 s, every-other-frame gone
            let t = 12.0 + Double($0) * 0.08
            return FrameIndexer.PacketStamp(pts: t, dts: t)
        }
        packets += stamps(interval: 0.04, count: 300, from: 12.0 + 249 * 0.08 + 0.04)  // baseline resumes
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(found.contains { $0.isVideo && $0.needsDecodeConfirm })
        let candidates = DamageDetector.clusterCandidates(found)
        #expect(candidates.contains { $0.hasVideoAnomaly && $0.start < 12.5 && $0.end > 31.0 })
    }

    @Test func sustainedSlowRegionRunningToEOFIsNotFlaggedAsAGap() {
        // The other side of defect 1: a slower cadence that runs to the file end is the permanent
        // PAFF→MBAFF cadence change (Clip Doctor's own output), not a bounded dropout — flagging it
        // makes the whole tail a multi-minute confirm decode. Only a slow region that returns to the
        // baseline cadence is a bounded excursion worth confirming, so this must stay silent.
        var packets = stamps(interval: 0.04, count: 400, from: 0)             // baseline
        packets += (1...300).map {                                           // slower, to EOF
            let t = 16.0 + Double($0) * 0.08
            return FrameIndexer.PacketStamp(pts: t, dts: t)
        }
        let found = DamageDetector.anomalies(streams: [video(packets)])
        #expect(!found.contains { $0.needsDecodeConfirm })
    }

    @Test func aLateResumeHoleWithinTheJudgedWindowIsCorroborated() {
        // Defect 2 (#80): a hole whose resume frame lands 1.3 s past the candidate end. The confirm
        // decode and the judged window now share one `tailLookahead` (1.5 s), so a frame exists past
        // the resume and the span is corroborated — before, the decode stopped at +1.0 s, produced no
        // frame past the hole, the span came back nil, and resolveZone's clean-decode veto dropped it.
        let interval = 0.04
        var frames = (0...250).map {                                          // good frames to 10.0 (candidate end)
            DamageDetector.DecodedFrame(pts: Double($0) * interval, corrupt: false)
        }
        frames += (0..<20).map {                                              // resume at 11.3 (1.3 s past end)
            DamageDetector.DecodedFrame(pts: 11.3 + Double($0) * interval, corrupt: false)
        }
        let candidate = DamageDetector.Candidate(start: 9.8, end: 10.0, hasVideoAnomaly: true)
        let span = DamageDetector.videoDamageSpan(
            frames: frames, window: (candidate.start - 1.0)...(candidate.end + 1.5),
            frameInterval: interval)
        #expect(span != nil)
    }

    @Test func gapOnlyVideoThatDecodesCleanIsNotVideoDamage() {
        // The seam candidate from the flood above: gap-only video evidence, no audio gap, and
        // a confirm decode that came back clean (span nil, frames produced). Old logic
        // (`span != nil || hasVideoAnomaly`) flagged it as a surviving video damage zone —
        // exactly the false positive a re-imported repaired file shows at its seam. The
        // authority rule drops it: a gap the decode passed through lost no picture.
        let seam = DamageDetector.Candidate(start: 80.0, end: 96.0, hasVideoAnomaly: true,
                                            hasOpaqueVideoAnomaly: false, hasAudioAnomaly: false)
        // Old logic was `span != nil || hasVideoAnomaly` → true here (a false video zone).
        #expect(DamageDetector.resolveZone(candidate: seam, span: nil,
                                           decodedFrameCount: 2000, containerStart: 0,
                                           frameInterval: 0.04) == nil)
    }

    @Test func gapVideoWithACompanionAudioGapDegradesToAnAudioZone() {
        // Same clean-decode gap, but a companion audio gap is present: the video isn't damaged
        // (decode clean), yet the audio hole is real — so the zone survives as audio-only and
        // the repair silence-fills it without re-encoding video.
        let c = DamageDetector.Candidate(start: 80.0, end: 96.0, hasVideoAnomaly: true,
                                         hasOpaqueVideoAnomaly: false, hasAudioAnomaly: true)
        let zone = DamageDetector.resolveZone(candidate: c, span: nil,
                                              decodedFrameCount: 2000, containerStart: 0,
                                              frameInterval: 0.04)
        #expect(zone == DamageZone(start: 80.0, end: 96.0, affectsVideo: false))
    }

    @Test func opaqueVideoAnomalyStaysVideoDamageEvenWhenTheDecodeIsClean() {
        // The 39 s dead zone: duplicate-DTS bursts the decoder silently absorbs (clean decode,
        // span nil) but which are genuine video damage. It must NOT be vetoed by the clean decode.
        let dead = DamageDetector.Candidate(start: 8132.0, end: 8171.0, hasVideoAnomaly: true,
                                            hasOpaqueVideoAnomaly: true, hasAudioAnomaly: true)
        let zone = DamageDetector.resolveZone(candidate: dead, span: nil,
                                              decodedFrameCount: 1500, containerStart: 0,
                                              frameInterval: 0.04)
        #expect(zone?.affectsVideo == true)
    }

    @Test func aGapKeepsItsVideoZoneWhenTheConfirmDecodeProducedNothing() {
        // A failed/empty confirm decode (kill, missing binary) can't veto a gap it never saw —
        // a real packet hole must not be silently downgraded, so the gap stays video damage.
        let c = DamageDetector.Candidate(start: 80.0, end: 96.0, hasVideoAnomaly: true,
                                         hasOpaqueVideoAnomaly: false, hasAudioAnomaly: false)
        #expect(DamageDetector.resolveZone(candidate: c, span: nil,
                                           decodedFrameCount: 0, containerStart: 0,
                                           frameInterval: 0.04)?.affectsVideo == true)
    }

    @Test func decodeCorroboratedGapIsStillVideoDamage() {
        // The honest case the veto must not break: a real dropout whose decode shows a hole
        // (span present). Gap-only evidence, but the decode corroborates it → video damage.
        let c = DamageDetector.Candidate(start: 41.96, end: 42.84, hasVideoAnomaly: true,
                                         hasOpaqueVideoAnomaly: false, hasAudioAnomaly: false)
        let zone = DamageDetector.resolveZone(candidate: c, span: (start: 41.9, end: 42.9),
                                              decodedFrameCount: 200, containerStart: 0,
                                              frameInterval: 0.04)
        #expect(zone?.affectsVideo == true)
        #expect(zone?.start == 41.9 && zone?.end == 42.9)
    }

    // MARK: zero-width invariant + truncated-ending widening (issue #79)

    @Test func truncatedPictureOnlyClusterWidensToOneFrameNotZeroWidth() {
        // A timestamp-less truncated picture (DamageDetector line ~77) clusters to a candidate
        // with start == end — an opaque video anomaly. Resolving it must never emit a
        // zero-width zone: it is the one partial frame, so it spans a single frame interval.
        let c = DamageDetector.Candidate(start: 100.0, end: 100.0, hasVideoAnomaly: true,
                                         hasOpaqueVideoAnomaly: true, hasAudioAnomaly: false)
        let zone = DamageDetector.resolveZone(candidate: c, span: nil,
                                              decodedFrameCount: 500, containerStart: 0,
                                              frameInterval: 0.04)
        #expect(zone?.affectsVideo == true)
        #expect(zone?.start == 100.0)
        #expect(abs((zone?.end ?? 0) - 100.04) < 1e-9)   // widened by one frame, never zero-width
    }

    @Test func nonZeroWidthLeavesRealZonesUntouchedButWidensCollapsedOnes() {
        // The invariant helper: a zone already at least one frame wide is unchanged; a collapsed
        // (start == end) or sub-frame span is widened to exactly one interval. No code path may
        // emit a zero-width DamageZone (issue #79).
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
        // The last-GOP EOF check's pure core (`eofZoneFromDecode`): the final index frame never
        // decodes (a truncated ending), so the decode stops one frame short of the last index
        // pts. The zone is a real video zone spanning that partial frame, ending at the file end
        // so the repair trims to it — never zero-width.
        let interval = 0.04
        let frames = (0..<50).map {
            DamageDetector.DecodedFrame(pts: 100.0 + Double($0) * interval, corrupt: false)
        }
        let lastDecoded = frames.last!.pts            // 101.96
        let lastPts = lastDecoded + interval          // 102.00 — the final index frame, undecoded
        let zone = DamageDetector.eofZoneFromDecode(
            frames: frames, lastPts: lastPts, seekPts: 100.0,
            localInterval: interval, containerStart: 0)
        let z = try #require(zone)
        #expect(z.affectsVideo)
        #expect(z.end - z.start >= interval - 1e-9)   // never zero-width
        #expect(z.end >= lastPts - 1e-9)              // reaches the file end so the repair trims
    }

    @Test func eofCleanTailYieldsNoZone() {
        // A clean tail that decodes to the last index frame is not a truncated ending.
        let interval = 0.04
        let frames = (0..<50).map {
            DamageDetector.DecodedFrame(pts: 100.0 + Double($0) * interval, corrupt: false)
        }
        #expect(DamageDetector.eofZoneFromDecode(
            frames: frames, lastPts: frames.last!.pts, seekPts: 100.0,
            localInterval: interval, containerStart: 0) == nil)
    }

    // MARK: confirm-decode parsing

    @Test func parseConfirmDecodeFlagsTheFrameAfterACorruptReport() {
        // The decoder's damage report prints before the frame's showinfo line.
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

    // MARK: damaged-span math

    @Test func corruptFramesAndHolesUnionIntoOneSpan() {
        // The synthetic h264 fixture's zone: a corrupt frame at 0.88 then a hole
        // 0.92 → 1.56 on a 0.04 interval. The span runs from just past the last good
        // frame to where good content resumes.
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
        // An audio-only event: the video window decodes clean → nil, and the zone
        // records as audio-only.
        let frames = (0..<100).map {
            DamageDetector.DecodedFrame(pts: Double($0) * 0.04, corrupt: false)
        }
        #expect(DamageDetector.videoDamageSpan(
            frames: frames, window: 0.0...4.0, frameInterval: 0.04) == nil)
    }

    @Test func damageOutsideTheWindowIsIgnored() {
        // A PS seek can land early and sweep unrelated content into the decode; only
        // damage near the candidate counts.
        let frames: [DamageDetector.DecodedFrame] = [
            .init(pts: 0.0, corrupt: true),       // landing artifact, outside window
            .init(pts: 0.04, corrupt: false),
            .init(pts: 0.08, corrupt: false),
        ] + (3..<80).map { .init(pts: Double($0) * 0.04, corrupt: false) }
        #expect(DamageDetector.videoDamageSpan(
            frames: frames, window: 1.0...3.0, frameInterval: 0.04) == nil)
    }

    @Test func marginIntervalIgnoresTheDamagedSpansOwnTiming() {
        // The 39 s dead zone emits garbled frames at half the real interval; the
        // window's cadence must come from the clean margins, not the damage.
        let candidate = DamageDetector.Candidate(start: 10.0, end: 14.0, hasVideoAnomaly: true)
        var frames = (0..<50).map { DamageDetector.DecodedFrame(pts: 8.0 + Double($0) * 0.04, corrupt: false) }   // clean head 8.0–9.96
        frames += (0..<100).map { .init(pts: 10.0 + Double($0) * 0.02, corrupt: false) }  // garbled middle
        frames += (0..<50).map { .init(pts: 14.5 + Double($0) * 0.04, corrupt: false) }   // clean tail
        let local = DamageDetector.marginInterval(frames: frames, candidate: candidate)
        #expect(local != nil && abs(local! - 0.04) < 1e-9)
    }

    @Test func marginIntervalIsNilOnThinMargins() {
        let candidate = DamageDetector.Candidate(start: 0.0, end: 100.0, hasVideoAnomaly: true)
        let frames = (0..<50).map { DamageDetector.DecodedFrame(pts: Double($0) * 0.04, corrupt: false) }
        #expect(DamageDetector.marginInterval(frames: frames, candidate: candidate) == nil)
    }

    // MARK: all-streams scan parsing

    @Test func parseAllStreamsGroupsByStreamAndBuildsTheSameIndex() {
        // Interleaved audio/video CSV (with the MPEG-2 trailing comma); the index
        // must come out exactly as parseIndex would build it from the video lines.
        let csv = """
        audio,1,0.540000,0.540000,K__,
        video,0,0.580000,0.500000,K__,
        video,0,0.540000,0.540000,___,
        audio,1,0.564000,0.564000,K__,
        video,0,N/A,0.580000,___,
        data,2,1.000000,1.000000,K__,
        """
        let scan = FrameIndexer.parseAllStreams(csv: csv)
        #expect(scan.streams.count == 2)   // the data stream is dropped
        #expect(scan.streams[0].streamIndex == 1 && !scan.streams[0].isVideo)
        #expect(scan.streams[1].streamIndex == 0 && scan.streams[1].isVideo)
        #expect(scan.streams[1].packets.count == 3)
        // pts-sorted index, missing pts refilled from dts (ADR-0006)
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
        // The truncated pictures (N/A,N/A) must reach the anomaly pass even though
        // the index skips them.
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

    // MARK: the row's damage line

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
