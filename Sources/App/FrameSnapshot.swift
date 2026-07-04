import SwiftUI
import UniformTypeIdentifiers

/// Everything needed to save the currently-displayed frame as a full-resolution PNG
/// (issue #89): the pre-filled file name, the folder the panel falls back to when the
/// user has no export-folder preference recorded, and a closure that decodes the frame
/// on demand. The producing model (cut-editor or output preview) builds this; the view
/// layer runs the save panel and writes the bytes.
struct FrameSnapshotRequest {
    let suggestedName: String
    /// The panel's fallback directory when `ExportPanelDefaults` has nothing to offer
    /// (the source clip's folder). `ExportPanelDefaults.startingDirectory` still wins.
    let defaultDirectory: URL?
    /// Decodes the PNG at the source's coded dimensions. `nil` on a decode failure.
    let makePNG: () async -> Data?
}

/// The single "Save Frame as Image…" pipeline shared by the cut-editor and the output
/// preview (issue #89): a filename-safe still name and a save panel that reuses the
/// export-folder preference (issue #87) and never instant-saves.
enum FrameSnapshot {
    /// A filesystem-safe still name: `"<clip stem> — HH.MM.SS.FF.png"`. The timecode's
    /// colons become dots — a colon is legal on APFS but Finder renders it as "/", which
    /// reads as a path separator — so the name is safe and unambiguous on every volume.
    static func fileName(clipName: String, timecode: String) -> String {
        let stem = (clipName as NSString).deletingPathExtension
        let base = stem.isEmpty ? "Frame" : stem
        let safeTimecode = timecode.replacingOccurrences(of: ":", with: ".")
        return "\(base) — \(safeTimecode).png"
    }

    /// Presents the save panel (pre-filled name, starting on the configured export
    /// folder — issue #87), then decodes and writes the PNG. A cancelled panel writes
    /// nothing; a decode failure or a write error surfaces an app-modal alert (the success
    /// path stays silent). The item is only reachable while a frame is displayed, so a
    /// failure here means an unexpected decode or filesystem error worth reporting.
    @MainActor
    static func save(_ request: FrameSnapshotRequest) {
        let panel = NSSavePanel()
        panel.title = "Save Frame as Image"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = request.suggestedName

        let defaults = ExportPanelDefaults()
        if let dir = defaults.startingDirectory ?? request.defaultDirectory {
            panel.directoryURL = dir
        }

        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "png" { url.appendPathExtension("png") }
        defaults.recordChosenFile(url)

        Task {
            guard let data = await request.makePNG() else {
                presentFailure("The frame could not be rendered for saving.")
                return
            }
            do {
                try data.write(to: url)
            } catch {
                presentFailure(error.localizedDescription)
            }
        }
    }

    /// Reports a save failure app-modally. The window-owning save panel has already closed by
    /// the time the async decode/write finishes, so an app-modal alert (not a sheet) is the
    /// right surface — a document error, not tied to a live window.
    @MainActor
    private static func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Save the Frame"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// The focused command the "Save Frame as Image…" menu item binds to (issue #89). The
/// output preview publishes it as a scene value while a frame is on screen; the menu
/// item reads it to drive its enabled state and action. The cut-editor is a separate
/// top-level window outside the document scene, so it can't publish here — it wires the
/// same shortcut locally instead (a seam #67's responder-chain routing will close).
struct SaveFrameCommand {
    let isEnabled: Bool
    let run: () -> Void
}

private struct SaveFrameCommandKey: FocusedValueKey {
    typealias Value = SaveFrameCommand
}

extension FocusedValues {
    var saveFrame: SaveFrameCommand? {
        get { self[SaveFrameCommandKey.self] }
        set { self[SaveFrameCommandKey.self] = newValue }
    }
}

/// The File-menu "Save Frame as Image…" item (issue #89). Standard File-menu position,
/// ⌃⌘S — a free, HIG-sane combination (the document's own ⌘S / ⇧⌘S are taken by
/// DocumentGroup). Enabled and driven by whichever surface owns the frame: the output
/// preview publishes `\.saveFrame` while it's key; the cut editor — a separate top-level
/// window outside the document scene — routes through `ActiveCutEditor` instead (issue
/// #67), which retired the cut editor's local hidden ⌃⌘S button.
struct SaveFrameMenuItem: View {
    @FocusedValue(\.saveFrame) private var command
    @ObservedObject private var active = ActiveCutEditor.shared

    var body: some View {
        if let command {                       // an in-scene surface (the preview) is key
            SaveFrameButton(isEnabled: command.isEnabled, run: command.run)
        } else if let model = active.model {   // a cut-editor window is key
            CutEditorSaveFrameButton(model: model)
        } else {
            SaveFrameButton(isEnabled: false) {}
        }
    }
}

/// Save Frame bound to the key cut-editor. A dedicated `@ObservedObject` view so the item
/// re-evaluates its enabled state as the model's `canSaveFrame` (a frame loads) changes.
private struct CutEditorSaveFrameButton: View {
    @ObservedObject var model: CutEditorModel

    var body: some View {
        SaveFrameButton(isEnabled: model.canSaveFrame) {
            guard let request = model.frameSnapshotRequest() else { return }
            FrameSnapshot.save(request)
        }
    }
}

private struct SaveFrameButton: View {
    let isEnabled: Bool
    let run: () -> Void

    var body: some View {
        Button("Save Frame as Image…") { run() }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(!isEnabled)
            .accessibilityIdentifier("menu.saveFrame")
    }
}
