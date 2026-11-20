import Foundation
import Testing
@testable import ClipStitcher

@MainActor
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

@MainActor
struct ProjectDocumentBatchTests {
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

@MainActor
struct ReconcileInOutTests {
    private func doc(inPoint: Int?, outPoint: Int?) -> (ProjectDocument, Clip.ID) {
        let d = ProjectDocument()
        var c = Clip(bookmark: Data(), displayName: "a.mp4")
        c.inPoint = inPoint
        c.outPoint = outPoint
        d.project.clips = [c]
        return (d, c.id)
    }

    private func plainIndex(count: Int) -> FrameIndex {
        FrameIndex(pts: (0..<count).map { Double($0) / 25 },
                   keyframeFlags: Array(repeating: false, count: count))
    }

    @Test func staleOutPointResetsBothAndQueuesTheNotice() {
        let (d, id) = doc(inPoint: 10, outPoint: 500)
        d.reconcileInOut(id: id, index: plainIndex(count: 100))
        #expect(d.project.clips[0].inPoint == nil)
        #expect(d.project.clips[0].outPoint == nil)
        #expect(d.inOutResets.contains(id))
    }

    @Test func fittingPointsAreKeptAndNothingIsQueued() {
        let (d, id) = doc(inPoint: 10, outPoint: 20)
        d.reconcileInOut(id: id, index: plainIndex(count: 100))
        #expect(d.project.clips[0].inPoint == 10)
        #expect(d.project.clips[0].outPoint == 20)
        #expect(d.inOutResets.isEmpty)
    }

    @Test func nilPointsAreLeftAloneAndNotQueued() {
        let (d, id) = doc(inPoint: nil, outPoint: nil)
        d.reconcileInOut(id: id, index: plainIndex(count: 100))
        #expect(d.project.clips[0].inPoint == nil)
        #expect(d.project.clips[0].outPoint == nil)
        #expect(d.inOutResets.isEmpty)
    }

    @Test func aClipIsNeverQueuedTwice() {
        let (d, id) = doc(inPoint: 10, outPoint: 500)
        d.reconcileInOut(id: id, index: plainIndex(count: 100))
        d.reconcileInOut(id: id, index: plainIndex(count: 100))
        #expect(d.inOutResets.filter { $0 == id }.count == 1)
    }
}

@MainActor
struct ReconcileCopyCutSnapTests {
    private func closedGopIndex() -> FrameIndex {
        var flags = Array(repeating: false, count: 16)
        flags[0] = true
        flags[8] = true
        return FrameIndex(pts: (0..<16).map { Double($0) / 25 }, keyframeFlags: flags)
    }

    private func doc(inPoint: Int?, outPoint: Int?, fieldCoded: Bool?, codec: String = "h264")
        -> (ProjectDocument, Clip.ID) {
        let d = ProjectDocument()
        var c = Clip(bookmark: Data(), displayName: "a.ts")
        c.video = VideoProperties(codec: codec, width: 720, height: 576,
                                  frameRate: "25/1", pixelFormat: "yuv420p")
        c.fieldCoded = fieldCoded
        c.inPoint = inPoint
        c.outPoint = outPoint
        d.project.clips = [c]
        return (d, c.id)
    }

    @Test func rawMidGopMarksResnapAndQueueTheNotice() {
        let (d, id) = doc(inPoint: 1, outPoint: 5, fieldCoded: true)
        d.reconcileInOut(id: id, index: closedGopIndex())
        #expect(d.project.clips[0].inPoint == 0)
        #expect(d.project.clips[0].outPoint == 7)
        #expect(d.inOutResets.contains(id))
    }

    @Test func aCrossedSnappedPairResetsBothAndQueuesTheNotice() {
        let (d, id) = doc(inPoint: 7, outPoint: 5, fieldCoded: true)
        d.reconcileInOut(id: id, index: closedGopIndex())
        #expect(d.project.clips[0].inPoint == nil)
        #expect(d.project.clips[0].outPoint == nil)
        #expect(d.inOutResets.contains(id))
    }

    @Test func anUnsnappablePointResetsBothAndQueuesTheNotice() {
        let (d, id) = doc(inPoint: 2, outPoint: 9, fieldCoded: true)
        let headless = FrameIndex(pts: (0..<16).map { Double($0) / 25 },
                                  keyframeFlags: Array(repeating: false, count: 16))
        d.reconcileInOut(id: id, index: headless)
        #expect(d.project.clips[0].inPoint == nil)
        #expect(d.project.clips[0].outPoint == nil)
        #expect(d.inOutResets.contains(id))
    }

    @Test func alreadySnappedMarksAreLeftIdenticalWithNoNotice() {
        let (d, id) = doc(inPoint: 8, outPoint: nil, fieldCoded: true)
        d.reconcileInOut(id: id, index: closedGopIndex())
        #expect(d.project.clips[0].inPoint == 8)
        #expect(d.project.clips[0].outPoint == nil)
        #expect(d.inOutResets.isEmpty)
    }

    @Test func progressiveStillProbingAndNonH264ClipsAreUntouched() {
        let shapes: [(Bool?, String)] = [(false, "h264"), (nil, "h264"), (true, "hevc")]
        for (fieldCoded, codec) in shapes {
            let (d, id) = doc(inPoint: 1, outPoint: 5, fieldCoded: fieldCoded, codec: codec)
            d.reconcileInOut(id: id, index: closedGopIndex())
            #expect(d.project.clips[0].inPoint == 1)
            #expect(d.project.clips[0].outPoint == 5)
            #expect(!d.inOutResets.contains(id))
        }
    }

    @Test func outOfRangePointsOnACopyCutClipStillResetToWholeClip() {
        let (d, id) = doc(inPoint: 1, outPoint: 500, fieldCoded: true)
        d.reconcileInOut(id: id, index: closedGopIndex())
        #expect(d.project.clips[0].inPoint == nil)
        #expect(d.project.clips[0].outPoint == nil)
        #expect(d.inOutResets.contains(id))
    }
}

struct ReopenResolutionTests {
    @Test func unresolvableSourceIsMissing() {
        #expect(ProjectDocument.reopenResolution(resolved: false, hasVideo: false) == .missing)
        #expect(ProjectDocument.reopenResolution(resolved: false, hasVideo: true) == .missing)
    }

    @Test func resolvableClipMissingProbedVideoReimports() {
        #expect(ProjectDocument.reopenResolution(resolved: true, hasVideo: false) == .reimport)
    }

    @Test func resolvableProbedClipIsReady() {
        #expect(ProjectDocument.reopenResolution(resolved: true, hasVideo: true) == .ready)
    }
}

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

struct ExportReadinessGateTests {
    private func clip(_ name: String) -> Clip { Clip(bookmark: Data(), displayName: name) }

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
        #expect(!message.contains("collapse to nothing"))
    }
}
