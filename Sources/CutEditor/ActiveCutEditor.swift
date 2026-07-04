import SwiftUI

/// The cut-editor window that is currently key, so the app-level menu commands
/// (Playback / Marking — issue #67) can route their actions to it.
///
/// The cut editor opens as a separate top-level `NSWindow` outside the
/// `DocumentGroup` scene (`CutEditorPresenter`), so SwiftUI's `@FocusedValue` /
/// `focusedSceneValue` — which only see the document scene's key window — can't
/// reach it. The presenter publishes the key cut-editor's model here as an
/// app-level `ObservableObject` instead, and the `.commands` menus read it (the
/// design note on #67 confirms `.commands` can observe an app-level object). The
/// output preview stays on `focusedSceneValue` (it *is* in the document scene); the
/// two paths are mutually exclusive — a cut-editor window being key resigns the
/// document scene, clearing its focused values, and vice versa.
@MainActor
final class ActiveCutEditor: ObservableObject {
    static let shared = ActiveCutEditor()

    /// The key cut-editor's model, or `nil` when no cut-editor window is key (a
    /// document window is key, the app is inactive, or a cut-editor popover such as
    /// Go To has taken key). Menu items disable and their shortcuts go inert when nil.
    @Published private(set) var model: CutEditorModel?

    init() {}

    /// A cut-editor window became key — its model now owns the Playback/Marking menus.
    func activate(_ model: CutEditorModel) {
        self.model = model
    }

    /// A cut-editor window resigned key or closed. Clears the active model only when it
    /// is the one resigning, so a resign that races ahead of another window's activate
    /// (or a stale close) can't blank out the newly-key editor.
    func resign(_ model: CutEditorModel?) {
        if self.model === model {
            self.model = nil
        }
    }
}
