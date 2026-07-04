import SwiftUI

@main
struct ClipStitcherApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { configuration in
            RootView(document: configuration.document)
        }

        // The standard Settings scene wires ⌘, automatically (issue #87).
        Settings {
            SettingsView()
        }
    }
}
