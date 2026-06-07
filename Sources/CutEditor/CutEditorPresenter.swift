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
        let hosting = NSHostingController(rootView: CutEditorView(model: model))
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
        models[id]?.stop()
        windows[id] = nil
        models[id] = nil
    }
}
