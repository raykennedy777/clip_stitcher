import Foundation
import Testing
@testable import ClipStitcher

/// Confirming a split replaces the clip with one clip per split range (issue #20,
/// ADR-0017): first range keeps the original identity, the rest are copies.
@MainActor
struct SplitClipTests {
    private func makeDocument() -> ProjectDocument {
        let doc = ProjectDocument()
        var first = Clip(bookmark: Data("src".utf8), displayName: "match.mp4")
        first.inPoint = 10
        first.outPoint = 90
        first.duration = 60
        first.frameCount = 1500
        first.audioSelections = [.stream(1)]
        let second = Clip(bookmark: Data(), displayName: "b.mp4")
        doc.project.clips = [first, second]
        doc.project.targetClipID = first.id
        return doc
    }

    @Test func splitReplacesTheClipWithOneClipPerRange() {
        let doc = makeDocument()
        let original = doc.project.clips[0]

        doc.splitClip(id: original.id, ranges: [
            SplitRanges.Range(inPoint: 10, outPoint: 49),
            SplitRanges.Range(inPoint: 50, outPoint: 69),
            SplitRanges.Range(inPoint: 70, outPoint: 90),
        ])

        let clips = doc.project.clips
        #expect(clips.count == 4)
        #expect(clips[0].inPoint == 10)
        #expect(clips[0].outPoint == 49)
        #expect(clips[1].inPoint == 50)
        #expect(clips[1].outPoint == 69)
        #expect(clips[2].inPoint == 70)
        #expect(clips[2].outPoint == 90)
        #expect(clips[3].displayName == "b.mp4")
    }

    @Test func theFirstRangeKeepsTheOriginalIdentitySoTheTargetSurvives() {
        let doc = makeDocument()
        let original = doc.project.clips[0]

        doc.splitClip(id: original.id, ranges: [
            SplitRanges.Range(inPoint: 10, outPoint: 49),
            SplitRanges.Range(inPoint: 50, outPoint: 90),
        ])

        #expect(doc.project.clips[0].id == original.id)
        #expect(doc.project.clips[1].id != original.id)
        #expect(doc.project.targetClipID == original.id)
        #expect(doc.project.targetClip?.outPoint == 49)
    }

    @Test func everyPieceCopiesTheSourceAndProbedState() {
        let doc = makeDocument()
        let original = doc.project.clips[0]

        doc.splitClip(id: original.id, ranges: [
            SplitRanges.Range(inPoint: nil, outPoint: 49),
            SplitRanges.Range(inPoint: 50, outPoint: nil),
        ])

        for piece in doc.project.clips.prefix(2) {
            #expect(piece.bookmark == original.bookmark)
            #expect(piece.duration == original.duration)
            #expect(piece.frameCount == original.frameCount)
            #expect(piece.audioSelections == [.stream(1)])
        }
    }

    @Test func piecesAreSuffixedInRangeOrder() {
        let doc = makeDocument()

        doc.splitClip(id: doc.project.clips[0].id, ranges: [
            SplitRanges.Range(inPoint: 10, outPoint: 49),
            SplitRanges.Range(inPoint: 50, outPoint: 90),
        ])

        #expect(doc.project.clips[0].displayName == "match.mp4 (1)")
        #expect(doc.project.clips[1].displayName == "match.mp4 (2)")
    }

    @Test func aSingleRangeIsNotASplit() {
        let doc = makeDocument()

        doc.splitClip(id: doc.project.clips[0].id, ranges: [
            SplitRanges.Range(inPoint: 20, outPoint: 80),
        ])

        #expect(doc.project.clips.count == 2)
        #expect(doc.project.clips[0].inPoint == 10) // untouched
    }

    @Test func anUnknownIdDoesNothing() {
        let doc = makeDocument()

        doc.splitClip(id: UUID(), ranges: [
            SplitRanges.Range(inPoint: nil, outPoint: 10),
            SplitRanges.Range(inPoint: 11, outPoint: nil),
        ])

        #expect(doc.project.clips.count == 2)
    }
}
