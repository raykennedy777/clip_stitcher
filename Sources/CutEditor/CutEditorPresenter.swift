import SwiftUI

/// Opens and tracks per-clip cut-editor windows. Each clip gets at most one window;
/// re-opening brings the existing one forward. Windows are separate top-level
/// windows (per the product spec) hosting the SwiftUI `CutEditorView`.
@MainActor
final class CutEditorPresenter: NSObject, ObservableObject, NSWindowDelegate {
    private var windows: [Clip.ID: NSWindow] = [:]
    private var models: [Clip.ID: CutEditorModel] = [:]

    func open(clip: Clip, document: ProjectDocument) {
        if let existing = windows[clip.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let url = document.url(for: clip) else {
            NSSound.beep()
            return
        }

        let model = CutEditorModel(clip: clip, url: url, document: document)
        let hosting = NSHostingController(rootView: CutEditorView(model: model, document: document))
        let window = NSWindow(contentViewController: hosting)
        window.title = clip.displayName
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 940, height: 700))
        window.delegate = self
        window.isReleasedWhenClosed = false

        model.onClose = { [weak window] in window?.close() }

        windows[clip.id] = window
        models[clip.id] = model
        window.center()
        window.makeKeyAndOrderFront(nil)

        Task { await model.load() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        // A closing window may never resign key first, so drop it from the menu router
        // here too (issue #67) before its model tears down.
        ActiveCutEditor.shared.resign(models[id])
        models[id]?.teardown()
        windows[id] = nil
        models[id] = nil
    }

    // MARK: - Menu routing (issue #67)
    //
    // The cut editor is outside the document scene, so the Playback/Marking menu
    // commands route to it through `ActiveCutEditor` rather than `@FocusedValue`.
    // Track the key cut-editor window and hand its model to the router; a resign
    // (switching to a document window, a Go To popover taking key, or app deactivation)
    // clears it so the menu items disable and their shortcuts go inert outside a
    // cut editor.

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key,
              let model = models[id] else { return }
        ActiveCutEditor.shared.activate(model)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        ActiveCutEditor.shared.resign(models[id])
    }
}
