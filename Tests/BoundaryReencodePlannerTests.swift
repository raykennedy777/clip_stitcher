import Testing
@testable import VidConform

/// Exercises the Milestone 2 planner (ADR-0009): a kept range becomes an ordered list
/// of logical segments tagged *copy* (stream-copy a keyframe-bounded span) or
/// *re-encode* (the partial GOPs at the head/tail), expressed purely as presentation
/// frame ranges so a CLI or a future libav backend can execute the same plan.
///
/// Boundary rules are asymmetric (#16): a copy may START only at a leading-picture-free
/// keyframe (count 0 — the strict rule), but may END at *any* counted keyframe `K`,
/// at presentation index `K − n_leading`: the segment-muxer cut before `K` sends its
/// leading pictures into the discarded segment.
struct BoundaryReencodePlannerTests {
    /// Builds leading-picture counts of `count` frames: 0 at the given clean boundaries
    /// (closed-GOP keyframes), plus any explicit open-GOP entries, nil elsewhere.
    private func counts(count: Int, boundaries: [Int], open: [Int: Int] = [:]) -> [Int?] {
        var c = Array<Int?>(repeating: nil, count: count)
        for b in boundaries { c[b] = 0 }
        for (k, n) in open { c[k] = n }
        return c
    }

    /// The canonical between-keyframes cut: re-encode the partial head, copy the
    /// keyframe-bounded middle, re-encode the partial tail — the recipe validated in the
    /// shell (head 7f, mid 250f, tail 8f). On clean boundaries the out-cut anchors at
    /// the copy range's end, exactly the pre-#16 behavior.
    @Test func reEncodesHeadAndTailAroundACopiedMiddle() {
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750, 1000]),
            frameCount: 1083, inFrame: 243, outFrame: 507)
        #expect(plan == [
            PlannedSegment(kind: .reEncode, range: 243..<250),
            PlannedSegment(kind: .copy,     range: 250..<500, outCutKeyframe: 500),
            PlannedSegment(kind: .reEncode, range: 500..<508),
        ])
    }

    /// A range that already starts and ends on copy-safe boundaries is a pure stream
    /// copy — no re-encode at all (M2 is never worse than M1 on boundary-aligned cuts).
    @Test func boundaryAlignedRangeIsPureCopy() {
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750]),
            frameCount: 1083, inFrame: 250, outFrame: 499)
        #expect(plan == [PlannedSegment(kind: .copy, range: 250..<500, outCutKeyframe: 500)])
    }

    /// A nil in/out means the clip boundary: copy from the file start / to the file end
    /// with no cut and no re-encode at that end.
    @Test func clipBoundariesCopyWithoutReEncoding() {
        let c = counts(count: 1083, boundaries: [0, 250, 500, 750])
        #expect(BoundaryReencodePlanner.plan(leadingCounts: c, frameCount: 1083, inFrame: nil, outFrame: nil)
                == [PlannedSegment(kind: .copy, range: 0..<1083)])
        #expect(BoundaryReencodePlanner.plan(leadingCounts: c, frameCount: 1083, inFrame: nil, outFrame: 507)
                == [PlannedSegment(kind: .copy, range: 0..<500, outCutKeyframe: 500),
                    PlannedSegment(kind: .reEncode, range: 500..<508)])
        #expect(BoundaryReencodePlanner.plan(leadingCounts: c, frameCount: 1083, inFrame: 243, outFrame: nil)
                == [PlannedSegment(kind: .reEncode, range: 243..<250),
                    PlannedSegment(kind: .copy, range: 250..<1083)])
    }

    /// When clean points are too sparse to bound a copy span (no copy-safe boundary in
    /// range, or only one), the whole kept range is re-encoded — correct, just costlier
    /// (ADR-0009: open-GOP degenerates toward full re-encode where clean points are rare).
    @Test func fullReEncodeWhenNoCopySpanFits() {
        // No boundary inside the range.
        #expect(BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 1000]),
            frameCount: 1083, inFrame: 200, outFrame: 300)
            == [PlannedSegment(kind: .reEncode, range: 200..<301)])
        // Exactly one boundary inside — can't bound a span.
        #expect(BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500]),
            frameCount: 1083, inFrame: 240, outFrame: 260)
            == [PlannedSegment(kind: .reEncode, range: 240..<261)])
    }

    /// Whatever the split, the segments are contiguous and cover exactly the kept range.
    @Test func segmentsContiguouslyCoverTheKeptRange() {
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750, 1000]),
            frameCount: 1083, inFrame: 243, outFrame: 507)
        #expect(plan.first?.range.lowerBound == 243)
        #expect(plan.last?.range.upperBound == 508)
        for (a, b) in zip(plan, plan.dropFirst()) {
            #expect(a.range.upperBound == b.range.lowerBound)
        }
        #expect(plan.reduce(0) { $0 + $1.range.count } == 508 - 243)
    }

    // MARK: asymmetric boundaries (#16)

    /// On open-GOP footage (every keyframe a CRA with leading pictures, the 2026 HEVC
    /// shape) a copy span may still END at any keyframe: the copy keeps
    /// `[start, K − n_leading)` and the tail re-encode covers the leading-picture slots
    /// and the rest — where pre-#16 the whole kept range re-encoded.
    @Test func openGopKeyframeEndsTheCopyAtKeyframeMinusLeading() {
        let c = counts(count: 1300, boundaries: [0],
                       open: [250: 3, 500: 3, 750: 3, 1000: 3, 1250: 3])
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1300, inFrame: nil, outFrame: 1200)
        #expect(plan == [
            PlannedSegment(kind: .copy, range: 0..<997, outCutKeyframe: 1000),
            PlannedSegment(kind: .reEncode, range: 997..<1201),
        ])
    }

    /// The strict rule survives on the start side: an open keyframe can END a span but
    /// never START one (its leading pictures would be orphaned at the seam), so a kept
    /// range with only open keyframes inside still re-encodes fully.
    @Test func openGopKeyframesCannotStartACopy() {
        let c = counts(count: 1300, boundaries: [0], open: [250: 2, 500: 2, 750: 2])
        #expect(BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1300, inFrame: 100, outFrame: 900)
            == [PlannedSegment(kind: .reEncode, range: 100..<901)])
    }

    /// The cut keyframe may sit beyond the kept range: with the out-point inside the
    /// keyframe's leading-picture slots, the copy still legally ends at `K − n_leading`
    /// and only the slots up to the out-point re-encode.
    @Test func endKeyframeMayLieBeyondTheOutPoint() {
        let c = counts(count: 1300, boundaries: [0], open: [1000: 4])
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1300, inFrame: nil, outFrame: 996)
        #expect(plan == [
            PlannedSegment(kind: .copy, range: 0..<996, outCutKeyframe: 1000),
            PlannedSegment(kind: .reEncode, range: 996..<997),
        ])
    }

    /// An out-point landing exactly on `K − n_leading` needs no tail re-encode at all:
    /// the cut alone produces the kept range.
    @Test func pureCopyWhenTheOutPointLandsExactlyBeforeTheLeadingPictures() {
        let c = counts(count: 1300, boundaries: [0], open: [1000: 4])
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1300, inFrame: nil, outFrame: 995)
        #expect(plan == [PlannedSegment(kind: .copy, range: 0..<996, outCutKeyframe: 1000)])
    }

    // MARK: damage repair (#47)

    private func zone(_ start: Double, _ end: Double, video: Bool = true) -> DamageZone {
        DamageZone(start: start, end: end, affectsVideo: video)
    }

    /// A damage zone inside the copied middle splits it: the zone is forced into a
    /// re-encode segment extending to the surrounding copy-safe boundaries (left: a
    /// legal copy END before the first damaged frame, leaving at least one good frame
    /// to hold; right: the first copy-safe START at/after the damage).
    @Test func zoneInsideTheCopySplitsItAroundARepair() {
        let z = zone(24.0, 25.5)
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750, 1000]),
            frameCount: 1083, inFrame: 243, outFrame: 1007,
            damage: [BoundaryReencodePlanner.DamageSpan(range: 600..<640, zone: z)])
        #expect(plan == [
            PlannedSegment(kind: .reEncode, range: 243..<250),
            PlannedSegment(kind: .copy, range: 250..<500, outCutKeyframe: 500),
            PlannedSegment(kind: .reEncode, range: 500..<750, damage: [z]),
            PlannedSegment(kind: .copy, range: 750..<1000, outCutKeyframe: 1000),
            PlannedSegment(kind: .reEncode, range: 1000..<1008),
        ])
    }

    /// No damage spans — the exact plan of today, byte for byte (the no-zones
    /// acceptance bar of issue #47).
    @Test func noDamageProducesTheIdenticalPlan() {
        let c = counts(count: 1083, boundaries: [0, 250, 500, 750, 1000])
        let damaged = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1083, inFrame: 243, outFrame: 507, damage: [])
        let plain = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1083, inFrame: 243, outFrame: 507)
        #expect(damaged == plain)
    }

    /// A zone whose frames sit entirely outside the kept range forces nothing.
    @Test func zoneOutsideTheKeptRangeIsIgnored() {
        let c = counts(count: 1083, boundaries: [0, 250, 500, 750, 1000])
        let outside = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1083, inFrame: 243, outFrame: 507,
            damage: [BoundaryReencodePlanner.DamageSpan(range: 600..<640, zone: zone(24, 25.5))])
        let plain = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1083, inFrame: 243, outFrame: 507)
        #expect(outside == plain)
    }

    /// Two zones whose extended repair spans meet merge into one re-encode segment
    /// carrying both zones — never two seams inside damaged territory.
    @Test func adjacentZonesMergeIntoOneRepair() {
        let z1 = zone(20.4, 20.8), z2 = zone(24.4, 24.8)
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750, 1000]),
            frameCount: 1083, inFrame: nil, outFrame: nil,
            damage: [BoundaryReencodePlanner.DamageSpan(range: 510..<520, zone: z1),
                     BoundaryReencodePlanner.DamageSpan(range: 610..<620, zone: z2)])
        #expect(plan == [
            PlannedSegment(kind: .copy, range: 0..<500, outCutKeyframe: 500),
            PlannedSegment(kind: .reEncode, range: 500..<750, damage: [z1, z2]),
            PlannedSegment(kind: .copy, range: 750..<1083),
        ])
    }

    /// A zone overlapping the head re-encode merges with it: one repair segment from
    /// the in-point to the first copy-safe start past the damage.
    @Test func zoneAtTheHeadMergesWithTheHeadReencode() {
        let z = zone(9.8, 9.9)
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750, 1000]),
            frameCount: 1083, inFrame: 243, outFrame: 1007,
            damage: [BoundaryReencodePlanner.DamageSpan(range: 245..<248, zone: z)])
        #expect(plan == [
            PlannedSegment(kind: .reEncode, range: 243..<250, damage: [z]),
            PlannedSegment(kind: .copy, range: 250..<1000, outCutKeyframe: 1000),
            PlannedSegment(kind: .reEncode, range: 1000..<1008),
        ])
    }

    /// A zone reaching past the last copy-safe start runs the repair to the range end,
    /// swallowing the tail re-encode (the EOF-truncation shape).
    @Test func zoneAtTheTailMergesWithTheTailReencode() {
        let z = zone(39.8, 40.3)
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750, 1000]),
            frameCount: 1083, inFrame: 243, outFrame: 1007,
            damage: [BoundaryReencodePlanner.DamageSpan(range: 995..<1005, zone: z)])
        #expect(plan == [
            PlannedSegment(kind: .reEncode, range: 243..<250),
            PlannedSegment(kind: .copy, range: 250..<750, outCutKeyframe: 750),
            PlannedSegment(kind: .reEncode, range: 750..<1008, damage: [z]),
        ])
    }

    /// Sparse clean points: the whole-range re-encode fallback becomes a repair
    /// carrying the zone, so the time-window select recipe applies there too.
    @Test func wholeRangeRepairWhenNoCopySpanFits() {
        let z = zone(10.0, 10.5)
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 1000]),
            frameCount: 1083, inFrame: 200, outFrame: 300,
            damage: [BoundaryReencodePlanner.DamageSpan(range: 250..<262, zone: z)])
        #expect(plan == [PlannedSegment(kind: .reEncode, range: 200..<301, damage: [z])])
    }

    /// An open-GOP copy END (`K − n_leading`) may bound the repair on the left: the
    /// preceding copy still cuts at the keyframe's DTS.
    @Test func openGopCopyEndBoundsTheRepair() {
        let z = zone(24.0, 24.4)
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1300, boundaries: [0, 250], open: [500: 3, 750: 3]),
            frameCount: 1300, inFrame: nil, outFrame: nil,
            damage: [BoundaryReencodePlanner.DamageSpan(range: 600..<640, zone: z)])
        #expect(plan == [
            PlannedSegment(kind: .copy, range: 0..<497, outCutKeyframe: 500),
            // No copy-safe START before the file end (all later keyframes are open),
            // so the repair runs to the end.
            PlannedSegment(kind: .reEncode, range: 497..<1300, damage: [z]),
        ])
    }

    /// A pure decoder hole (no index frames inside the zone — `range` is empty) still
    /// forces a repair bracketing the hole.
    @Test func pureHoleZoneStillForcesARepair() {
        let z = zone(24.0, 24.1)
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750, 1000]),
            frameCount: 1083, inFrame: nil, outFrame: nil,
            damage: [BoundaryReencodePlanner.DamageSpan(range: 600..<600, zone: z)])
        #expect(plan == [
            PlannedSegment(kind: .copy, range: 0..<500, outCutKeyframe: 500),
            PlannedSegment(kind: .reEncode, range: 500..<750, damage: [z]),
            PlannedSegment(kind: .copy, range: 750..<1083),
        ])
    }

    // MARK: zone-time → frame mapping (#47)

    /// Zones map to frame spans through the index pts by absolute time (zone times are
    /// container-start-relative): the span brackets the zone's time range — first frame
    /// at/after the start through the last frame before the end. Audio-only zones are
    /// dropped here (the defensive audio legs already repair those).
    @Test func damageSpansMapZoneTimesThroughPts() {
        let pts = (0..<100).map { 10.0 + Double($0) * 0.04 }   // abs pts, file starts at 10s
        let spans = BoundaryReencodePlanner.damageSpans(
            zones: [DamageZone(start: 1.0, end: 1.2, affectsVideo: true),
                    DamageZone(start: 2.0, end: 2.04, affectsVideo: false)],
            pts: pts, containerStart: 10.0)
        // abs 11.0–11.2 → frames 25..<30 (pts 11.0, 11.04, …, 11.16 damaged; 11.2 good)
        #expect(spans == [BoundaryReencodePlanner.DamageSpan(
            range: 25..<30, zone: DamageZone(start: 1.0, end: 1.2, affectsVideo: true))])
    }

    /// A zone covering a span with no index frames (missing packets) maps to an empty
    /// range at the insertion point — still a repairable span.
    @Test func damageSpansMapHolesToEmptyRanges() {
        var pts = (0..<50).map { Double($0) * 0.04 }
        pts += (75..<100).map { Double($0) * 0.04 }   // frames 50..74 missing (2.0–2.96)
        let spans = BoundaryReencodePlanner.damageSpans(
            zones: [DamageZone(start: 2.0, end: 2.96, affectsVideo: true)],
            pts: pts, containerStart: 0)
        #expect(spans == [BoundaryReencodePlanner.DamageSpan(
            range: 50..<50, zone: DamageZone(start: 2.0, end: 2.96, affectsVideo: true))])
    }

    /// The span widens past the zone until the next frame's **dts** clears everything
    /// inside it (max dts *and* max pts): the copy cut after the repair is placed on
    /// the boundary keyframe's dts, and any in-zone packet whose timestamps reach past
    /// that cut would be swept into the kept copy (the h264 fixture's mis-framed
    /// garbage packets did exactly this — 3 in-zone packets in a kept piece, and a
    /// timestamp-less choke at the concat). On a B-frame cadence the widening is the
    /// reorder depth; with dts == pts it is zero.
    @Test func damageSpansWidenUntilDtsClearsTheZone() {
        let pts = (0..<100).map { 10.0 + Double($0) * 0.04 }
        let zone = DamageZone(start: 1.0, end: 1.2, affectsVideo: true)
        // Reordered stream: every dts trails its pts by two slots.
        let reordered = BoundaryReencodePlanner.damageSpans(
            zones: [zone], pts: pts, dts: pts.map { $0 - 0.08 }, containerStart: 10.0)
        // Zone frames [25,30): max pts 11.16; dts clears it first at frame 32 (11.16+).
        #expect(reordered == [BoundaryReencodePlanner.DamageSpan(range: 25..<32, zone: zone)])
        // Garbled in-zone dts reaching far past the zone sweeps the bound with it.
        var garbled = pts.map { $0 - 0.08 }
        garbled[27] = 11.4
        let swept = BoundaryReencodePlanner.damageSpans(
            zones: [zone], pts: pts, dts: garbled, containerStart: 10.0)
        #expect(swept == [BoundaryReencodePlanner.DamageSpan(range: 25..<38, zone: zone)])
    }
}
