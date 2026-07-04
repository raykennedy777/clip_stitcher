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
        }

        // The standard Settings scene wires ⌘, automatically (issue #87).
        Settings {
            SettingsView()
        }
    }
}
