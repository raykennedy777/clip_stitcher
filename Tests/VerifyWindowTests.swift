import Testing
import Foundation
@testable import ClipStitcher

struct VerifyWindowTests {
    static let rate = 25.0
    static let keyframeEvery = 25
    static let copySafeEveryNthKeyframe = 4

    static func piece(frames: Int, copySafeEvery: Int? = copySafeEveryNthKeyframe)
        -> (keyframePts: [Int: Double], copySafe: [Int: Bool], span: ClosedRange<Double>) {
        var pts: [Int: Double] = [:]
        var safe: [Int: Bool] = [:]
        var keyframeOrdinal = 0
        for frame in stride(from: 0, to: frames, by: keyframeEvery) {
            pts[frame] = Double(frame) / rate
            safe[frame] = copySafeEvery.map { keyframeOrdinal % $0 == 0 } ?? false
            keyframeOrdinal += 1
        }
        return (pts, safe, 0...(Double(frames - 1) / rate))
    }

    static func windows(_ kinds: [PlannedSegment.Kind], _ counts: [Int],
                        frames: Int? = nil, copySafeEvery: Int? = copySafeEveryNthKeyframe,
                        damageAt: Int? = nil) -> [ClosedRange<Double>]? {
        var lower = 0
        let plan = zip(kinds, counts).enumerated().map { i, pair -> PlannedSegment in
            let (kind, count) = pair
            defer { lower += count }
            return PlannedSegment(
                kind: kind, range: lower..<(lower + count),
                damage: damageAt == i ? [DamageZone(start: 0, end: 1, affectsVideo: true)] : [])
        }
        let total = frames ?? counts.reduce(0, +)
        let p = piece(frames: total, copySafeEvery: copySafeEvery)
        return BoundaryReencodeEngine.verifyWindows(
            plan: plan, outputCounts: counts, pieceKeyframePts: p.keyframePts,
            pieceCopySafeFlags: p.copySafe, pieceSpan: p.span)
    }

    static func at(_ frame: Int) -> Double { Double(frame) / rate }

    @Test func aHeadReEncodeIsCoveredFromThePieceStartThroughTheFirstCopiedGop() throws {
        let windows = try #require(Self.windows([.reEncode, .copy], [40, 3960]))
        #expect(windows.count == 1)
        #expect(windows[0].lowerBound == 0)
        #expect(windows[0].upperBound == Self.at(75))
    }

    @Test func aTailReEncodeOpensAtTheLastCopySafeKeyframeBeforeItsSeam() throws {
        let windows = try #require(Self.windows([.copy, .reEncode], [2000, 40]))
        #expect(windows.count == 1)
        #expect(windows[0].lowerBound == Self.at(1900))
        #expect(windows[0].upperBound == Self.at(2039))
    }

    @Test func bothEdgesGetTheirOwnWindowAndTheMiddleIsNotDecoded() throws {
        let windows = try #require(Self.windows([.reEncode, .copy, .reEncode], [40, 3920, 40]))
        #expect(windows.count == 2)
        #expect(windows[0] == 0...Self.at(75))
        #expect(windows[1].lowerBound == Self.at(3900))
        #expect(windows[1].upperBound == Self.at(3999))
        let decoded = windows.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        #expect(decoded < (Self.at(3999) - 0) / 10)
    }

    @Test func aMiddleRepairSegmentGetsAWindowAroundBothOfItsSeams() throws {
        let windows = try #require(
            Self.windows([.copy, .reEncode, .copy], [2000, 40, 1960], damageAt: 1))
        #expect(windows.count == 1)
        #expect(windows[0].lowerBound == Self.at(1900))
        #expect(windows[0].upperBound == Self.at(2075))
    }

    @Test func aCopyOnlyPlanIsBoundedToItsCutStart() throws {
        let windows = try #require(Self.windows([.copy], [4000]))
        #expect(windows == [0...Self.at(25)])
    }

    @Test func aPieceShorterThanItsWindowsDecodesWhole() {
        #expect(Self.windows([.reEncode, .copy, .reEncode], [10, 30, 10]) == nil)
    }

    @Test func overlappingWindowsMergeIntoOne() throws {
        let windows = try #require(Self.windows(
            [.copy, .reEncode, .copy, .reEncode, .copy], [2000, 50, 50, 40, 1860],
            copySafeEvery: 1))
        #expect(windows.count == 1)
        #expect(windows[0].lowerBound == Self.at(1975))
        #expect(windows[0].upperBound == Self.at(2175))
    }

    @Test func aCopyBodyWithNoCopySafeKeyframeWidensToTheCopySegmentsStart() throws {
        let windows = try #require(Self.windows(
            [.copy, .reEncode, .copy], [2000, 40, 1960], copySafeEvery: nil))
        #expect(windows == [0...Self.at(2075)])
    }

    @Test func widenedToACopyStartThatIsThePieceStartTheWindowBecomesTheWholePiece() {
        #expect(Self.windows([.copy, .reEncode], [2000, 40], copySafeEvery: nil) == nil)
    }

    @Test func everyKeyframeCopySafeOpensTheWindowOneGopBeforeTheSeam() throws {
        let windows = try #require(
            Self.windows([.copy, .reEncode], [2000, 40], copySafeEvery: 1))
        #expect(windows[0].lowerBound == Self.at(1975))
    }

    @Test func aCopySafeKeyframeAdjacentToTheSeamStillOpensTheWindow() throws {
        let windows = try #require(Self.windows([.copy, .reEncode], [1901, 40], copySafeEvery: 1))
        #expect(windows[0].lowerBound == Self.at(1900))
        #expect(windows[0].upperBound == Self.at(1940))
    }

    @Test func aPlanThatDoesNotMatchItsOutputCountsDecodesWhole() {
        #expect(Self.windows([.reEncode, .copy], [40]) == nil)
    }

    @Test func anEmptyPlanDecodesWhole() {
        let p = Self.piece(frames: 100)
        #expect(BoundaryReencodeEngine.verifyWindows(
            plan: [], outputCounts: [], pieceKeyframePts: p.keyframePts,
            pieceCopySafeFlags: p.copySafe, pieceSpan: p.span) == nil)
    }

    @Test func aPieceWithNoSpanDecodesWhole() {
        let p = Self.piece(frames: 4000)
        #expect(BoundaryReencodeEngine.verifyWindows(
            plan: [PlannedSegment(kind: .reEncode, range: 0..<40),
                   PlannedSegment(kind: .copy, range: 40..<4000)],
            outputCounts: [40, 3960], pieceKeyframePts: p.keyframePts,
            pieceCopySafeFlags: p.copySafe, pieceSpan: 0...0) == nil)
    }

    @Test func aCopyWithNoSecondKeyframeRunsTheWindowToThePieceEnd() throws {
        let windows = try #require(Self.windows([.copy, .reEncode, .copy], [2000, 40, 10]))
        #expect(windows == [Self.at(1900)...Self.at(2049)])
    }

    @Test func framecrcReportsTheFirstPacketsPresentationTime() {
        let dump = """
        #tb 0: 1/1000
        #media_type 0: video
        0,       44760,       44780,       20,    30165, 0x8a1b2c3d
        """
        #expect(BoundaryReencodeEngine.framecrcFirstPts(dump) == 44.78)
    }

    @Test func framecrcWithNoTimedRowReadsAsNoLanding() {
        #expect(BoundaryReencodeEngine.framecrcFirstPts("#tb 0: 1/1000\n") == nil)
        #expect(BoundaryReencodeEngine.framecrcFirstPts("") == nil)
        #expect(BoundaryReencodeEngine.framecrcFirstPts(
            "#tb 0: 1/90000\n0,       N/A,       N/A,       0,    100, 0x0") == nil)
    }
}
