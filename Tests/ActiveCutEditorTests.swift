import Testing
import Foundation
@testable import ClipStitcher

/// The menu-routing model behind the Playback / Marking menus (issue #67): which
/// cut-editor a menu command acts on, and when it disables. The cut editor is a separate
/// top-level window outside the document scene, so `ActiveCutEditor` — not `@FocusedValue`
/// — carries the key window's model to the app-level `.commands`.
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
        // A cut-editor window resigning key (or closing) drops it from the router, so the
        // menu items disable and their shortcuts go inert outside a cut editor.
        let router = ActiveCutEditor()
        let model = makeModel()
        router.activate(model)
        router.resign(model)
        #expect(router.model == nil)
    }

    @Test func resigningAnOtherEditorLeavesTheActiveOne() {
        // resign of a window that isn't the active one (a stale close, or a resign that
        // races behind another window's activate) must not blank out the key editor.
        let router = ActiveCutEditor()
        let active = makeModel(name: "a")
        let other = makeModel(name: "b")
        router.activate(active)
        router.resign(other)
        #expect(router.model === active)
    }

    @Test func switchingKeyEditorsHandsOverTheModel() {
        // Bringing a second cut editor forward: its becomeKey replaces the first.
        let router = ActiveCutEditor()
        let first = makeModel(name: "first")
        let second = makeModel(name: "second")
        router.activate(first)
        router.activate(second)
        #expect(router.model === second)
    }
}

/// The transport enable gates the Playback / Marking menus read (issue #67), so a menu
/// item never fires against a clip that is still indexing or empty.
@MainActor
struct CutEditorMenuGateTests {
    private func makeModel() -> CutEditorModel {
        CutEditorModel(
            clip: Clip(bookmark: Data(), displayName: "clip"),
            url: URL(fileURLWithPath: "/tmp/clip.mkv"), document: ProjectDocument())
    }

    @Test func cannotStepWhileIndexingOrEmpty() {
        let model = makeModel()
        // Fresh: indexing, no frames.
        #expect(model.canStep == false)

        model.isIndexing = false
        #expect(model.canStep == false)   // still no frames

        model.frameCount = 100
        #expect(model.canStep == true)
    }

    @Test func sceneScanGateAlsoBlocksWhileScanning() {
        let model = makeModel()
        model.isIndexing = false
        model.frameCount = 100
        #expect(model.canScene == true)

        model.isSceneScanning = true
        #expect(model.canScene == false)   // one scan at a time
        #expect(model.canStep == true)     // stepping still allowed
    }
}
