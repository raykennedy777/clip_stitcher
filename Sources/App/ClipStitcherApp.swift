import SwiftUI

@main
struct ClipStitcherApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { configuration in
            RootView(document: configuration.document)
        }
        .commands {
            // "Save Frame as Image…" (issue #89), standard File-menu position after
            // Save. Its enabled state and action come from whichever surface publishes
            // `\.saveFrame` — the output preview here; the cut-editor wires the same
            // shortcut in its own window (a seam #67 will consolidate).
            CommandGroup(after: .saveItem) {
                SaveFrameMenuItem()
            }

            // Playback and Marking menus (issue #67) surface the frame-surface shortcuts
            // where macOS users look for them. Placed after the standard View menu, they
            // route to the key cut-editor (via ActiveCutEditor) or, for the shared
            // transport actions, the output preview (via the previewTransport focused
            // value). See MenuCommands.swift.
            CommandMenu("Playback") {
                PlaybackCommands()
            }
            CommandMenu("Marking") {
                MarkingCommands()
            }
        }

        // The standard Settings scene wires ⌘, automatically (issue #87).
        Settings {
            SettingsView()
        }
    }
}
