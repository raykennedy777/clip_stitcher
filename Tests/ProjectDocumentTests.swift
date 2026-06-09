import Foundation
import Testing
@testable import VidConform

/// Duplicate inserts a copy directly after the original — same source, probed
/// properties, and in/out selection, but its own identity (ROADMAP slice 7).
struct ProjectDocumentDuplicateTests {
    private func makeDocument() -> ProjectDocument {
        let doc = ProjectDocument()
        var first = Clip(bookmark: Data(), displayName: "a.mp4")
        first.inPoint = 10
        first.outPoint = 20
        first.duration = 60
        first.frameCount = 1500
        let second = Clip(bookmark: Data(), displayName: "b.mp4")
        doc.project.clips = [first, second]
        doc.project.targetClipID = first.id
        return doc
    }

    @Test func duplicateInsertsACopyDirectlyAfterTheOriginal() {
        let doc = makeDocument()
        let original = doc.project.clips[0]

        let newID = doc.duplicateClip(id: original.id)

        #expect(doc.project.clips.count == 3)
        #expect(doc.project.clips[1].id == newID)
        #expect(doc.project.clips[2].displayName == "b.mp4")
    }

    @Test func duplicateCopiesEverythingButTheIdentity() {
        let doc = makeDocument()
        let original = doc.project.clips[0]

        guard let newID = doc.duplicateClip(id: original.id),
              let copy = doc.project.clips.first(where: { $0.id == newID }) else {
            Issue.record("duplicate produced no clip")
            return
        }

        #expect(copy.id != original.id)
        #expect(copy.bookmark == original.bookmark)
        #expect(copy.displayName == original.displayName)
        #expect(copy.inPoint == 10)
        #expect(copy.outPoint == 20)
        #expect(copy.duration == original.duration)
        #expect(copy.frameCount == original.frameCount)
    }

    @Test func duplicateNeverStealsTheTargetRole() {
        let doc = makeDocument()
        let targetID = doc.project.targetClipID

        doc.duplicateClip(id: doc.project.clips[0].id)

        #expect(doc.project.targetClipID == targetID)
    }

    @Test func duplicatingAnUnknownIdDoesNothing() {
        let doc = makeDocument()

        let newID = doc.duplicateClip(id: UUID())

        #expect(newID == nil)
        #expect(doc.project.clips.count == 2)
    }
}
