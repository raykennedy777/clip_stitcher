import Foundation
import Testing
@testable import ClipStitcher

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

/// Batch actions on a multi-selection (issue #12): every batch lands as one
/// mutation, in timeline order regardless of the selection set's own order.
struct ProjectDocumentBatchTests {
    /// Five ready clips named clip0…clip4; clip0 is the target.
    private func makeDocument() -> ProjectDocument {
        let doc = ProjectDocument()
        doc.project.clips = (0..<5).map { Clip(bookmark: Data(), displayName: "clip\($0).mp4") }
        doc.project.targetClipID = doc.project.clips[0].id
        for clip in doc.project.clips { doc.importStates[clip.id] = .ready }
        return doc
    }

    private func names(_ doc: ProjectDocument) -> [String] {
        doc.project.clips.map(\.displayName)
    }

    private func ids(_ doc: ProjectDocument, _ positions: Int...) -> Set<Clip.ID> {
        Set(positions.map { doc.project.clips[$0].id })
    }

    @Test func moveDownCompactsANonContiguousSelection() {
        let doc = makeDocument()

        doc.move(ids: ids(doc, 1, 3), by: 1)

        #expect(names(doc) == ["clip0.mp4", "clip2.mp4", "clip4.mp4", "clip1.mp4", "clip3.mp4"])
    }

    @Test func moveUpCompactsANonContiguousSelection() {
        let doc = makeDocument()

        doc.move(ids: ids(doc, 1, 3), by: -1)

        #expect(names(doc) == ["clip1.mp4", "clip3.mp4", "clip0.mp4", "clip2.mp4", "clip4.mp4"])
    }

    @Test func moveBlockedAtTheEdgeDoesNothing() {
        let doc = makeDocument()

        doc.move(ids: ids(doc, 0, 2), by: -1)

        #expect(names(doc) == ["clip0.mp4", "clip1.mp4", "clip2.mp4", "clip3.mp4", "clip4.mp4"])
    }

    @Test func duplicateInsertsCopiesContiguouslyBelowTheBottommostSelected() {
        let doc = makeDocument()

        let newIDs = doc.duplicateClips(ids: ids(doc, 2, 0))

        #expect(names(doc) == ["clip0.mp4", "clip1.mp4", "clip2.mp4",
                               "clip0.mp4", "clip2.mp4",
                               "clip3.mp4", "clip4.mp4"])
        // The returned ids are the copies, in timeline order.
        #expect(newIDs == [doc.project.clips[3].id, doc.project.clips[4].id])
        #expect(Set(newIDs).isDisjoint(with: ids(doc, 0, 1, 2)))
    }

    @Test func duplicateCopiesAdoptTheOriginalsImportState() {
        let doc = makeDocument()

        let newIDs = doc.duplicateClips(ids: ids(doc, 1, 2))

        for id in newIDs {
            #expect(doc.importStates[id] == .ready)
        }
    }

    @Test func oneUndoRemovesAllDuplicates() {
        let doc = makeDocument()
        let undo = UndoManager()
        doc.undoManager = undo

        doc.duplicateClips(ids: ids(doc, 1, 3))
        #expect(doc.project.clips.count == 7)
        undo.undo()

        #expect(names(doc) == ["clip0.mp4", "clip1.mp4", "clip2.mp4", "clip3.mp4", "clip4.mp4"])
    }

    @Test func deleteRemovesAllSelectedAndReassignsTheTarget() {
        let doc = makeDocument()
        let survivor = doc.project.clips[2].id

        doc.deleteClips(ids: ids(doc, 0, 1, 4))

        #expect(names(doc) == ["clip2.mp4", "clip3.mp4"])
        // The deleted clips' runtime state is dropped; the target falls to the
        // first remaining clip.
        #expect(doc.project.targetClipID == survivor)
        #expect(doc.importStates.count == 2)
    }

    @Test func oneUndoRestoresAWholeBatchDelete() {
        let doc = makeDocument()
        let target = doc.project.targetClipID
        let undo = UndoManager()
        doc.undoManager = undo

        doc.deleteClips(ids: ids(doc, 0, 2, 4))
        undo.undo()

        #expect(names(doc) == ["clip0.mp4", "clip1.mp4", "clip2.mp4", "clip3.mp4", "clip4.mp4"])
        #expect(doc.project.targetClipID == target)
    }

    @Test func audioSelectionsFanOutToEverySelectedClip() {
        let doc = makeDocument()
        let track = AudioProperties(codec: "ac3", sampleRate: 48000, channels: 2)
        for i in [1, 3] {
            doc.project.clips[i].audioTracks = [track, track]
        }
        // The monitored-track choice is per-clip and outside the fan-out.
        doc.project.clips[3].monitoredAudioTrack = 1

        doc.setAudioSelections(ids: ids(doc, 1, 3), selections: [.stream(1), .stream(0)])

        for i in [1, 3] {
            #expect(doc.project.clips[i].audioSelections == [.stream(1), .stream(0)])
        }
        #expect(doc.project.clips[1].monitoredAudioTrack == nil)
        #expect(doc.project.clips[3].monitoredAudioTrack == 1)
        #expect(doc.project.clips[2].audioSelections == nil)
    }

    @Test func audioSelectionsFanOutIsOneUndoStep() {
        let doc = makeDocument()
        let track = AudioProperties(codec: "ac3", sampleRate: 48000, channels: 2)
        for i in [1, 3] {
            doc.project.clips[i].audioTracks = [track, track]
        }
        let undo = UndoManager()
        doc.undoManager = undo

        doc.setAudioSelections(ids: ids(doc, 1, 3), selections: [.stream(1)])
        undo.undo()

        #expect(doc.project.clips[1].audioSelections == nil)
        #expect(doc.project.clips[3].audioSelections == nil)
    }
}

/// A relink to a shorter file must not leave in/out points the new frame index can't
/// hold — they'd trap the export planner (issue #74). The validation rule runs once the
/// re-imported frame count is known: both in range → keep; either out → reset both.
struct InOutRevalidationTests {
    @Test func bothPointsInRangeAreKept() {
        let result = ProjectDocument.validatedInOut(inPoint: 10, outPoint: 20, frameCount: 100)
        #expect(result.inPoint == 10)
        #expect(result.outPoint == 20)
        #expect(result.didReset == false)
    }

    @Test func nilPointsStayNilAndDoNotReset() {
        let result = ProjectDocument.validatedInOut(inPoint: nil, outPoint: nil, frameCount: 100)
        #expect(result.inPoint == nil)
        #expect(result.outPoint == nil)
        #expect(result.didReset == false)
    }

    @Test func lastFrameOutPointIsInRange() {
        // outPoint is an inclusive frame index; the last valid position is frameCount - 1.
        let result = ProjectDocument.validatedInOut(inPoint: 0, outPoint: 99, frameCount: 100)
        #expect(result.outPoint == 99)
        #expect(result.didReset == false)
    }

    @Test func outPointPastTheNewEndResetsBothPoints() {
        let result = ProjectDocument.validatedInOut(inPoint: 10, outPoint: 500, frameCount: 100)
        #expect(result.inPoint == nil)
        #expect(result.outPoint == nil)
        #expect(result.didReset)
    }

    @Test func inPointAtOrPastTheNewEndResetsBothPoints() {
        // A shorter file whose new count is <= the stored inPoint (equal is out of range —
        // valid positions are 0..<count).
        let result = ProjectDocument.validatedInOut(inPoint: 100, outPoint: nil, frameCount: 100)
        #expect(result.inPoint == nil)
        #expect(result.outPoint == nil)
        #expect(result.didReset)
    }

    @Test func inPointFitsButOutPointDoesNotResetsBoth() {
        let result = ProjectDocument.validatedInOut(inPoint: 5, outPoint: 100, frameCount: 100)
        #expect(result.inPoint == nil)
        #expect(result.outPoint == nil)
        #expect(result.didReset)
    }
}

/// The preview's track choice persists per project (pinned #8 decision): a new
/// optional field on the project model — old saves decode to the default, track 1.
struct MonitoredOutputTrackPersistenceTests {
    @Test func oldSavesDecodeToNilMeaningTrackOne() throws {
        let json = #"{"clips":[],"output":{"mode":"connect","type":"videoAndAudio","container":"ts"}}"#
        let project = try JSONDecoder().decode(VidProject.self, from: Data(json.utf8))
        #expect(project.monitoredOutputTrack == nil)
    }

    @Test func trackChoiceRoundTrips() throws {
        var project = VidProject()
        project.monitoredOutputTrack = 2
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(VidProject.self, from: data)
        #expect(decoded.monitoredOutputTrack == 2)
    }
}

/// Export must gate on import state (issue #78): a clip still probing/indexing has no
/// probed video, so planning it would default the smart-render encoder to libx264 and
/// silently re-encode the source wrong. The button disables with a visible reason and
/// `export()` refuses with a specific, user-readable error.
struct ExportReadinessGateTests {
    private func clip(_ name: String) -> Clip { Clip(bookmark: Data(), displayName: name) }

    // MARK: per-clip reason (the export() gate)

    @Test func readyAndUnknownStatesAreNotBlocked() {
        let c = clip("a.mp4")
        #expect(ProjectDocument.clipNotReadyReason(for: c, state: .ready) == nil)
        #expect(ProjectDocument.clipNotReadyReason(for: c, state: nil) == nil)
    }

    @Test func probingAndIndexingClipsAreBlocked() {
        let c = clip("a.mp4")
        #expect(ProjectDocument.clipNotReadyReason(for: c, state: .probing)?.contains("being analysed") == true)
        #expect(ProjectDocument.clipNotReadyReason(for: c, state: .indexing)?.contains("being analysed") == true)
    }

    @Test func failedClipReasonNamesTheImportError() {
        let reason = ProjectDocument.clipNotReadyReason(for: clip("a.mp4"), state: .failed("No video track"))
        #expect(reason?.contains("No video track") == true)
        #expect(reason?.contains("Remove or relink") == true)
    }

    @Test func sourceMissingClipIsBlocked() {
        let reason = ProjectDocument.clipNotReadyReason(for: clip("a.mp4"), state: .sourceMissing)
        #expect(reason?.contains("missing") == true)
        #expect(reason?.contains("Relink") == true)
    }

    // MARK: aggregate reason (the Output button)

    @Test func noReasonWhenEmptyOrAllReady() {
        #expect(ProjectDocument.exportDisabledReason(clips: [], states: [:]) == nil)
        let a = clip("a.mp4"), b = clip("b.mp4")
        let states: [Clip.ID: ImportState] = [a.id: .ready, b.id: .ready]
        #expect(ProjectDocument.exportDisabledReason(clips: [a, b], states: states) == nil)
    }

    @Test func analysingReasonNamesTheCountWithPluralisation() {
        let a = clip("a.mp4"), b = clip("b.mp4"), c = clip("c.mp4")
        let one: [Clip.ID: ImportState] = [a.id: .probing, b.id: .ready]
        #expect(ProjectDocument.exportDisabledReason(clips: [a, b], states: one) == "Analysing 1 clip…")
        let two: [Clip.ID: ImportState] = [a.id: .probing, b.id: .indexing, c.id: .ready]
        #expect(ProjectDocument.exportDisabledReason(clips: [a, b, c], states: two) == "Analysing 2 clips…")
    }

    @Test func analysingTakesPriorityOverUnresolved() {
        // A mix of still-analysing and failed clips reports the analysing count first —
        // it resolves on its own; the failed row's error is shown in the source list.
        let a = clip("a.mp4"), b = clip("b.mp4")
        let states: [Clip.ID: ImportState] = [a.id: .probing, b.id: .failed("No video track")]
        #expect(ProjectDocument.exportDisabledReason(clips: [a, b], states: states) == "Analysing 1 clip…")
    }

    @Test func unresolvedReasonWhenNothingIsAnalysing() {
        let a = clip("a.mp4"), b = clip("b.mp4")
        let one: [Clip.ID: ImportState] = [a.id: .failed("No video track"), b.id: .ready]
        #expect(ProjectDocument.exportDisabledReason(clips: [a, b], states: one)?.contains("One clip couldn’t be imported") == true)
        let two: [Clip.ID: ImportState] = [a.id: .failed("x"), b.id: .sourceMissing]
        #expect(ProjectDocument.exportDisabledReason(clips: [a, b], states: two)?.hasPrefix("2 clips couldn’t be imported") == true)
    }

    // MARK: export() refuses an unready clip

    @MainActor
    @Test func exportDuringProbingFailsWithReadinessNotInvalidPlan() async {
        let doc = ProjectDocument()
        let c = clip("a.mp4")
        doc.project.clips = [c]
        doc.importStates[c.id] = .probing

        await doc.export(to: URL(fileURLWithPath: NSTemporaryDirectory() + "vidconform-78-out.mp4"))

        guard case .failed(let message) = doc.exportStatus else {
            Issue.record("expected .failed, got \(doc.exportStatus)")
            return
        }
        #expect(message.contains("being analysed"))
        // Not the generic invalidPlan wording the old path produced.
        #expect(!message.contains("collapse to nothing"))
    }
}
