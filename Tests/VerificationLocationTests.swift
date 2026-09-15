import Testing
import Foundation
@testable import ClipStitcher

/// The location line every verification refusal opens with, and the bounded excerpt the CLI
/// prints in place of a thousands-of-lines decoder tail (issue #113).
struct VerificationLocationTests {

    // MARK: the location line

    @Test func theLineNamesTheClipThePieceAndThePlan() {
        let location = VerificationLocation(
            clipIndex: 3, displayName: "part 4", piece: "c3_joined.mkv",
            plan: [PlannedSegment(kind: .reEncode, range: 1234..<14682),
                   PlannedSegment(kind: .copy, range: 14682..<56790)])
        #expect(location.line
            == "clip 3 “part 4” — piece c3_joined.mkv — plan: reEncode [1234,14682) · copy [14682,56790)")
    }

    /// Clip Doctor and the engine's own callers can have no name to quote; the line then
    /// carries the index and the piece alone, with no empty quotes.
    @Test func anUnnamedClipDropsTheQuotedName() {
        let location = VerificationLocation(
            clipIndex: 0, piece: "c0_joined.ts",
            plan: [PlannedSegment(kind: .copy, range: 0..<100)])
        #expect(location.line == "clip 0 — piece c0_joined.ts — plan: copy [0,100)")
    }

    /// A conformed piece is one whole-clip re-encode, so it has no segment plan to summarize.
    @Test func aConformedPieceSaysConformInPlaceOfAPlan() {
        let location = VerificationLocation(
            clipIndex: 2, displayName: "b-roll", piece: "c2_conform.mp4", conformed: true)
        #expect(location.line == "clip 2 “b-roll” — piece c2_conform.mp4 — plan: conform")
    }

    /// The line is also the CLI's verdict line, so a long plan is counted, not spelled out.
    @Test func aLongPlanCountsTheSegmentsItDoesNotSpellOut() {
        let plan = (0..<9).map { PlannedSegment(kind: .copy, range: ($0 * 10)..<($0 * 10 + 10)) }
        let line = VerificationLocation(clipIndex: 1, piece: "c1_joined.ts", plan: plan).line
        #expect(line.hasSuffix("· +5 more"))
        #expect(!line.contains("[40,50)"))
    }

    /// A repaired segment reads as a repair, not as the plain re-encode it is built from.
    @Test func aDamagedSegmentReadsAsARepair() {
        let plan = [PlannedSegment(kind: .reEncode, range: 0..<50,
                                   damage: [DamageZone(start: 1, end: 2, affectsVideo: true)])]
        #expect(VerificationLocation(clipIndex: 0, piece: "c0_joined.ts", plan: plan).line
            .hasSuffix("plan: repair [0,50)"))
    }

    // MARK: the thrown message

    @Test func theRefusalOpensWithTheLocationLineThenWhatFailedThenTheDetail() {
        let location = VerificationLocation(
            clipIndex: 3, displayName: "part 4", piece: "c3_joined.mkv",
            plan: [PlannedSegment(kind: .copy, range: 0..<10)])
        let message = location.message("A decode check failed on the cut.", detail: "could not find ref")
        #expect(message == """
            clip 3 “part 4” — piece c3_joined.mkv — plan: copy [0,10)
            A decode check failed on the cut.
            could not find ref
            """)
        // The payload's first line is the location line, so the CLI's verdict can quote it
        // without a second source of truth.
        let described = ExportError.verificationFailed(message).errorDescription ?? ""
        #expect(described.components(separatedBy: "\n")[1] == location.line)
    }

    @Test func aMessageWithNoDetailIsJustTheLocationAndTheLabel() {
        let location = VerificationLocation(clipIndex: 0, piece: "c0_conform.mp4", conformed: true)
        #expect(location.message("The conformed clip has irregular timestamps: x")
            == "clip 0 — piece c0_conform.mp4 — plan: conform\nThe conformed clip has irregular timestamps: x")
    }

    // MARK: the bounded excerpt

    @Test func aShortMessagePassesThroughUnchanged() {
        let text = "one\ntwo\nthree"
        #expect(BoundedExcerpt.bounded(text) == text)
    }

    /// The boundary case: exactly head + tail lines is still short enough to print whole.
    @Test func exactlyFifteenLinesPassThroughUnchanged() {
        let text = (1...15).map { "line \($0)" }.joined(separator: "\n")
        #expect(BoundedExcerpt.bounded(text) == text)
    }

    @Test func aFloodKeepsFiveHeadLinesAMarkerAndTenTailLines() {
        let text = (1...3096).map { "line \($0)" }.joined(separator: "\n")
        let lines = BoundedExcerpt.bounded(text).components(separatedBy: "\n")
        #expect(lines.count == 16)
        #expect(Array(lines.prefix(5)) == (1...5).map { "line \($0)" })
        #expect(lines[5] == "… 3081 more lines …")
        #expect(Array(lines.suffix(10)) == (3087...3096).map { "line \($0)" })
    }
}
