import SwiftUI

@main
struct ClipStitcherApp: App {
    init() {
        Task.detached(priority: .background) { WorkDirectorySweeper.sweep() }
    }

    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { configuration in
            RootView(document: configuration.document)
        }
        .commands {
            CommandGroup(after: .saveItem) {
                SaveFrameMenuItem()
            }

            CommandMenu("Playback") {
                PlaybackCommands()
            }
            CommandMenu("Marking") {
                MarkingCommands()
            }
        }

        Settings {
            SettingsView()
        }
    }
}
