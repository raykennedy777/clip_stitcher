import Testing
import Foundation
@testable import ClipStitcher

/// Pins `BoundaryReencodeEngine.verifyWindows` — the pure part of the bounded verify decode
/// (ADR-0030, issue #114). The shell de-risk settled *what* a window has to cover and how its
/// decode may be entered; these cases pin the arithmetic that places one, for every plan shape
/// the executor can hand it.
///
/// The fixture is one piece shape reused throughout: 25 fps, keyframes every 25 frames (a
/// second), and every **fourth** keyframe copy-safe — the broadcast shape the de-risk
/// synthesised, where a copy may start only at the sparse IDRs and every keyframe between is
/// an open-GOP keyframe carrying leading pictures.
struct VerifyWindowTests {
    static let rate = 25.0
    static let keyframeEvery = 25
    static let copySafeEveryNthKeyframe = 4

    /// A piece of `frames` frames: pts at 1/25, a keyframe each second, every fourth of those
    /// copy-safe. `copySafeEvery` overrides how sparse the copy-safe ones are (1 = closed GOP,
    /// where every keyframe qualifies; `nil` = none at all).
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

    /// Seconds, for reading the expectations against the 25 fps fixture.
    static func at(_ frame: Int) -> Double { Double(frame) / rate }

    // MARK: the plan shapes

    @Test func aHeadReEncodeIsCoveredFromThePieceStartThroughTheFirstCopiedGop() throws {
        // [reEncode 0..<40][copy 40..<4000]: no copy before the seam, so the window opens at
        // the piece start; it closes at the *second* keyframe of the copy, one GOP in.
        let windows = try #require(Self.windows([.reEncode, .copy], [40, 3960]))
        #expect(windows.count == 1)
        #expect(windows[0].lowerBound == 0)
        #expect(windows[0].upperBound == Self.at(75))   // keyframes at 50 and 75 inside the copy
    }

    @Test func aTailReEncodeOpensAtTheLastCopySafeKeyframeBeforeItsSeam() throws {
        // [copy 0..<2000][reEncode 2000..<2040]: the seam is at frame 2000; the last keyframe
        // before it is 1975, and the copy-safe one at or before that is 1900 (every 4th).
        let windows = try #require(Self.windows([.copy, .reEncode], [2000, 40]))
        #expect(windows.count == 1)
        #expect(windows[0].lowerBound == Self.at(1900))
        #expect(windows[0].upperBound == Self.at(2039))   // no copy after it: the piece end
    }

    @Test func bothEdgesGetTheirOwnWindowAndTheMiddleIsNotDecoded() throws {
        let windows = try #require(Self.windows([.reEncode, .copy, .reEncode], [40, 3920, 40]))
        #expect(windows.count == 2)
        #expect(windows[0] == 0...Self.at(75))
        #expect(windows[1].lowerBound == Self.at(3900))
        #expect(windows[1].upperBound == Self.at(3999))
        // The point of the exercise: the copied middle is not decoded at all.
        let decoded = windows.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        #expect(decoded < (Self.at(3999) - 0) / 10)
    }

    @Test func aMiddleRepairSegmentGetsAWindowAroundBothOfItsSeams() throws {
        // [copy][repair][copy]: one window, opening at the copy-safe keyframe before the
        // repair and closing one copied GOP after it.
        let windows = try #require(
            Self.windows([.copy, .reEncode, .copy], [2000, 40, 1960], damageAt: 1))
        #expect(windows.count == 1)
        #expect(windows[0].lowerBound == Self.at(1900))
        #expect(windows[0].upperBound == Self.at(2075))   // keyframes 2050, 2075 in the copy
    }

    @Test func aCopyOnlyPlanIsBoundedToItsCutStart() throws {
        // A pure copy has one seam — where the cut starts — so one window from the piece
        // start through its second keyframe.
        let windows = try #require(Self.windows([.copy], [4000]))
        #expect(windows == [0...Self.at(25)])
    }

    @Test func aPieceShorterThanItsWindowsDecodesWhole() {
        // Two seams a few frames apart: the windows merge and cover the piece, which is the
        // whole-piece decode.
        #expect(Self.windows([.reEncode, .copy, .reEncode], [10, 30, 10]) == nil)
    }

    @Test func overlappingWindowsMergeIntoOne() throws {
        // Two repairs two seconds apart: the first window closes at frame 2075 and the second
        // opens at 2040, so they overlap and come back as one span — still a bound, not the
        // whole piece.
        let windows = try #require(Self.windows(
            [.copy, .reEncode, .copy, .reEncode, .copy], [2000, 50, 50, 40, 1860],
            copySafeEvery: 1))
        #expect(windows.count == 1)
        #expect(windows[0].lowerBound == Self.at(1975))
        #expect(windows[0].upperBound == Self.at(2175))
    }

    // MARK: where the window may open

    @Test func aCopyBodyWithNoCopySafeKeyframeWidensToTheCopySegmentsStart() throws {
        // Open-GOP HEVC: every keyframe in the copy body carries leading pictures. The rule
        // is never "start at one anyway" — a decode entered there orphans them and floods
        // (ADR-0030 step 5) — so the window widens to the copy's own start, copy-safe by
        // construction.
        let windows = try #require(Self.windows(
            [.copy, .reEncode, .copy], [2000, 40, 1960], copySafeEvery: nil))
        #expect(windows == [0...Self.at(2075)])
    }

    @Test func widenedToACopyStartThatIsThePieceStartTheWindowBecomesTheWholePiece() {
        // The same widening with nothing after the re-encode: the window opens at the piece
        // start and runs to the piece end, which is the whole-piece decode said plainly.
        #expect(Self.windows([.copy, .reEncode], [2000, 40], copySafeEvery: nil) == nil)
    }

    @Test func everyKeyframeCopySafeOpensTheWindowOneGopBeforeTheSeam() throws {
        // Closed-GOP H.264: the nearest copy-safe keyframe before the seam is the last
        // keyframe before it, so the window is one GOP plus the re-encode.
        let windows = try #require(
            Self.windows([.copy, .reEncode], [2000, 40], copySafeEvery: 1))
        #expect(windows[0].lowerBound == Self.at(1975))
    }

    @Test func aCopySafeKeyframeAdjacentToTheSeamStillOpensTheWindow() throws {
        // The seam lands one frame after a copy-safe keyframe (measured on the de-risk's
        // H.264 piece, where the tail window came out 0.8 s long). The window is short but it
        // still contains the last copied frame before the seam, which is what it must cover.
        let windows = try #require(Self.windows([.copy, .reEncode], [1901, 40], copySafeEvery: 1))
        #expect(windows[0].lowerBound == Self.at(1900))
        #expect(windows[0].upperBound == Self.at(1940))
    }

    // MARK: degenerate inputs ask for the whole piece

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
        // A copy body shorter than two keyframes has no "second keyframe" to close on, so the
        // window runs to the piece end rather than guessing one.
        let windows = try #require(Self.windows([.copy, .reEncode, .copy], [2000, 40, 10]))
        #expect(windows == [Self.at(1900)...Self.at(2049)])
    }

    // MARK: the landing probe's reader

    @Test func framecrcReportsTheFirstPacketsPresentationTime() {
        // `stream, dts, pts, duration, size, crc` at the header's time base: the probe reads
        // the *pts* column, and the mkv piece's 1/1000 base makes 44780 ticks 44.78 s.
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
