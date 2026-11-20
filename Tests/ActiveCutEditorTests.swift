import Testing
import Foundation
@testable import ClipStitcher

@MainActor
struct ActiveCutEditorTests {
    private func makeModel(name: String = "clip") -> CutEditorModel {
        let clip = Clip(bookmark: Data(), displayName: name)
        return CutEditorModel(
            clip: clip, url: URL(fileURLWithPath: "/tmp/\(name).mkv"), document: ProjectDocument())
    }

    @Test func startsWithNoActiveEditor() {
        #expect(ActiveCutEditor().model == nil)
    }

    @Test func activatePublishesTheKeyEditorsModel() {
        let router = ActiveCutEditor()
        let model = makeModel()
        router.activate(model)
        #expect(router.model === model)
    }

    @Test func resigningTheActiveEditorClearsIt() {
        let router = ActiveCutEditor()
        let model = makeModel()
        router.activate(model)
        router.resign(model)
        #expect(router.model == nil)
    }

    @Test func resigningAnOtherEditorLeavesTheActiveOne() {
        let router = ActiveCutEditor()
        let active = makeModel(name: "a")
        let other = makeModel(name: "b")
        router.activate(active)
        router.resign(other)
        #expect(router.model === active)
    }

    @Test func switchingKeyEditorsHandsOverTheModel() {
        let router = ActiveCutEditor()
        let first = makeModel(name: "first")
        let second = makeModel(name: "second")
        router.activate(first)
        router.activate(second)
        #expect(router.model === second)
    }
}

@MainActor
struct CutEditorMenuGateTests {
    private func makeModel() -> CutEditorModel {
        CutEditorModel(
            clip: Clip(bookmark: Data(), displayName: "clip"),
            url: URL(fileURLWithPath: "/tmp/clip.mkv"), document: ProjectDocument())
    }

    @Test func cannotStepWhileIndexingOrEmpty() {
        let model = makeModel()
        #expect(model.canStep == false)

        model.isIndexing = false
        #expect(model.canStep == false)

        model.frameCount = 100
        #expect(model.canStep == true)
    }

    @Test func sceneScanGateAlsoBlocksWhileScanning() {
        let model = makeModel()
        model.isIndexing = false
        model.frameCount = 100
        #expect(model.canScene == true)

        model.isSceneScanning = true
        #expect(model.canScene == false)
        #expect(model.canStep == true)
    }
}
