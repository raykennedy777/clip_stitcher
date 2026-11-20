import SwiftUI
import UniformTypeIdentifiers

struct FrameSnapshotRequest {
    let suggestedName: String
    let defaultDirectory: URL?
    let makePNG: () async -> Data?
}

enum FrameSnapshot {
    static func fileName(clipName: String, timecode: String) -> String {
        let stem = (clipName as NSString).deletingPathExtension
        let base = stem.isEmpty ? "Frame" : stem
        let safeTimecode = timecode.replacingOccurrences(of: ":", with: ".")
        return "\(base) — \(safeTimecode).png"
    }

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

struct SaveFrameMenuItem: View {
    @FocusedValue(\.saveFrame) private var command
    @ObservedObject private var active = ActiveCutEditor.shared

    var body: some View {
        if let command {
            SaveFrameButton(isEnabled: command.isEnabled, run: command.run)
        } else if let model = active.model {
            CutEditorSaveFrameButton(model: model)
        } else {
            SaveFrameButton(isEnabled: false) {}
        }
    }
}

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
