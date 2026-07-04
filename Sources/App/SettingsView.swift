import SwiftUI
import AppKit

/// The app's Settings window (⌘,, issue #87). Exactly two preferences, both
/// `@AppStorage`-backed so they persist across launches:
///
///  1. **Default export folder** — where the export / Clip Doctor / (future
///     snapshot) save panels start: remember the last choice, or a pinned folder.
///  2. **Default container** — the container a new project starts with.
///
/// Deliberately small and standard (one `Form`, no tabs) — nothing speculative was
/// added beyond these two.
struct SettingsView: View {
    @AppStorage(AppSettings.Key.exportFolderMode)
    private var folderMode: ExportFolderMode = .lastUsed
    @AppStorage(AppSettings.Key.fixedExportFolderPath)
    private var fixedFolderPath: String = ""
    @AppStorage(AppSettings.Key.defaultContainer)
    private var defaultContainer: Container = .mkv

    var body: some View {
        Form {
            Section("Saving") {
                Picker("Save panels start in", selection: $folderMode) {
                    ForEach(ExportFolderMode.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.folderMode")

                if folderMode == .fixed {
                    LabeledContent("Folder") {
                        HStack {
                            Text(fixedFolderDisplay)
                                .foregroundStyle(fixedFolderPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("settings.fixedFolderPath")
                            Spacer(minLength: 8)
                            Button("Choose…", action: chooseFixedFolder)
                                .accessibilityIdentifier("settings.chooseFolder")
                        }
                    }
                }
            }

            Section("New projects") {
                Picker("Default container", selection: $defaultContainer) {
                    ForEach(Container.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.container")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fixedFolderDisplay: String {
        fixedFolderPath.isEmpty
            ? "No folder chosen"
            : (fixedFolderPath as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFixedFolder() {
        let panel = NSOpenPanel()
        panel.title = "Default Export Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !fixedFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: fixedFolderPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fixedFolderPath = url.path
    }
}
