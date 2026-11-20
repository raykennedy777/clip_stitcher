import Testing
@testable import ClipStitcher

struct BoundaryReencodePlannerTests {
    private func counts(count: Int, boundaries: [Int], open: [Int: Int] = [:]) -> [Int?] {
        var c = Array<Int?>(repeating: nil, count: count)
        for b in boundaries { c[b] = 0 }
        for (k, n) in open { c[k] = n }
        return c
    }

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

    @Test func boundaryAlignedRangeIsPureCopy() {
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500, 750]),
            frameCount: 1083, inFrame: 250, outFrame: 499)
        #expect(plan == [PlannedSegment(kind: .copy, range: 250..<500, outCutKeyframe: 500)])
    }

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

    @Test func fullReEncodeWhenNoCopySpanFits() {
        #expect(BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 1000]),
            frameCount: 1083, inFrame: 200, outFrame: 300)
            == [PlannedSegment(kind: .reEncode, range: 200..<301)])
        #expect(BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 250, 500]),
            frameCount: 1083, inFrame: 240, outFrame: 260)
            == [PlannedSegment(kind: .reEncode, range: 240..<261)])
    }

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

    @Test func openGopKeyframesCannotStartACopy() {
        let c = counts(count: 1300, boundaries: [0], open: [250: 2, 500: 2, 750: 2])
        #expect(BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1300, inFrame: 100, outFrame: 900)
            == [PlannedSegment(kind: .reEncode, range: 100..<901)])
    }

    @Test func endKeyframeMayLieBeyondTheOutPoint() {
        let c = counts(count: 1300, boundaries: [0], open: [1000: 4])
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1300, inFrame: nil, outFrame: 996)
        #expect(plan == [
            PlannedSegment(kind: .copy, range: 0..<996, outCutKeyframe: 1000),
            PlannedSegment(kind: .reEncode, range: 996..<997),
        ])
    }

    @Test func pureCopyWhenTheOutPointLandsExactlyBeforeTheLeadingPictures() {
        let c = counts(count: 1300, boundaries: [0], open: [1000: 4])
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1300, inFrame: nil, outFrame: 995)
        #expect(plan == [PlannedSegment(kind: .copy, range: 0..<996, outCutKeyframe: 1000)])
    }

    private func zone(_ start: Double, _ end: Double, video: Bool = true) -> DamageZone {
        DamageZone(start: start, end: end, affectsVideo: video)
    }

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

    @Test func noDamageProducesTheIdenticalPlan() {
        let c = counts(count: 1083, boundaries: [0, 250, 500, 750, 1000])
        let damaged = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1083, inFrame: 243, outFrame: 507, damage: [])
        let plain = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1083, inFrame: 243, outFrame: 507)
        #expect(damaged == plain)
    }

    @Test func zoneOutsideTheKeptRangeIsIgnored() {
        let c = counts(count: 1083, boundaries: [0, 250, 500, 750, 1000])
        let outside = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1083, inFrame: 243, outFrame: 507,
            damage: [BoundaryReencodePlanner.DamageSpan(range: 600..<640, zone: zone(24, 25.5))])
        let plain = BoundaryReencodePlanner.plan(
            leadingCounts: c, frameCount: 1083, inFrame: 243, outFrame: 507)
        #expect(outside == plain)
    }

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

    @Test func wholeRangeRepairWhenNoCopySpanFits() {
        let z = zone(10.0, 10.5)
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1083, boundaries: [0, 1000]),
            frameCount: 1083, inFrame: 200, outFrame: 300,
            damage: [BoundaryReencodePlanner.DamageSpan(range: 250..<262, zone: z)])
        #expect(plan == [PlannedSegment(kind: .reEncode, range: 200..<301, damage: [z])])
    }

    @Test func openGopCopyEndBoundsTheRepair() {
        let z = zone(24.0, 24.4)
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts(count: 1300, boundaries: [0, 250], open: [500: 3, 750: 3]),
            frameCount: 1300, inFrame: nil, outFrame: nil,
            damage: [BoundaryReencodePlanner.DamageSpan(range: 600..<640, zone: z)])
        #expect(plan == [
            PlannedSegment(kind: .copy, range: 0..<497, outCutKeyframe: 500),
            PlannedSegment(kind: .reEncode, range: 497..<1300, damage: [z]),
        ])
    }

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

    @Test func damageSpansMapZoneTimesThroughPts() {
        let pts = (0..<100).map { 10.0 + Double($0) * 0.04 }
        let spans = BoundaryReencodePlanner.damageSpans(
            zones: [DamageZone(start: 1.0, end: 1.2, affectsVideo: true),
                    DamageZone(start: 2.0, end: 2.04, affectsVideo: false)],
            pts: pts, containerStart: 10.0)
        #expect(spans == [BoundaryReencodePlanner.DamageSpan(
            range: 25..<30, zone: DamageZone(start: 1.0, end: 1.2, affectsVideo: true))])
    }

    @Test func damageSpansMapHolesToEmptyRanges() {
        var pts = (0..<50).map { Double($0) * 0.04 }
        pts += (75..<100).map { Double($0) * 0.04 }
        let spans = BoundaryReencodePlanner.damageSpans(
            zones: [DamageZone(start: 2.0, end: 2.96, affectsVideo: true)],
            pts: pts, containerStart: 0)
        #expect(spans == [BoundaryReencodePlanner.DamageSpan(
            range: 50..<50, zone: DamageZone(start: 2.0, end: 2.96, affectsVideo: true))])
    }

    @Test func damageSpansWidenUntilDtsClearsTheZone() {
        let pts = (0..<100).map { 10.0 + Double($0) * 0.04 }
        let zone = DamageZone(start: 1.0, end: 1.2, affectsVideo: true)
        let reordered = BoundaryReencodePlanner.damageSpans(
            zones: [zone], pts: pts, dts: pts.map { $0 - 0.08 }, containerStart: 10.0)
        #expect(reordered == [BoundaryReencodePlanner.DamageSpan(range: 25..<32, zone: zone)])
        var garbled = pts.map { $0 - 0.08 }
        garbled[27] = 11.4
        let swept = BoundaryReencodePlanner.damageSpans(
            zones: [zone], pts: pts, dts: garbled, containerStart: 10.0)
        #expect(swept == [BoundaryReencodePlanner.DamageSpan(range: 25..<38, zone: zone)])
    }
}
