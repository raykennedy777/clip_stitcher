import Testing
import Foundation
@testable import ClipStitcher

/// The two Settings-window preferences (issue #87): the default-container fallback,
/// and the shared save-panel starting-directory / last-choice mechanism.
struct AppSettingsTests {

    /// A throwaway `UserDefaults` domain so tests never touch `.standard`.
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    /// A real directory to point the fixed/last-used folder at (the helper only
    /// returns paths that still exist as directories).
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Default container

    @Test func defaultContainerFallsBackToMkvWhenUnset() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettings.defaultContainer(defaults) == .mkv)
    }

    @Test func defaultContainerHonoursAStoredChoice() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Container.ts.rawValue, forKey: AppSettings.Key.defaultContainer)
        #expect(AppSettings.defaultContainer(defaults) == .ts)
    }

    @Test func defaultContainerIgnoresAnUnknownRawValue() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("avi", forKey: AppSettings.Key.defaultContainer)
        #expect(AppSettings.defaultContainer(defaults) == .mkv)
    }

    // MARK: - Panel starting directory

    @Test func startingDirectoryIsNilWhenNothingRecorded() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ExportPanelDefaults(defaults: defaults).startingDirectory == nil)
    }

    @Test func lastUsedModeReturnsTheRecordedFolder() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let helper = ExportPanelDefaults(defaults: defaults)
        helper.recordChosenFolder(dir)

        #expect(helper.startingDirectory?.standardizedFileURL == dir.standardizedFileURL)
    }

    @Test func recordChosenFileStoresItsParentFolder() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let helper = ExportPanelDefaults(defaults: defaults)
        helper.recordChosenFile(dir.appendingPathComponent("out.mkv"))

        #expect(helper.startingDirectory?.standardizedFileURL == dir.standardizedFileURL)
    }

    @Test func fixedModeReturnsThePinnedFolder() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixed = try makeTempDir()
        let last = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: fixed)
            try? FileManager.default.removeItem(at: last)
        }
        defaults.set(ExportFolderMode.fixed.rawValue, forKey: AppSettings.Key.exportFolderMode)
        defaults.set(fixed.path, forKey: AppSettings.Key.fixedExportFolderPath)
        defaults.set(last.path, forKey: AppSettings.Key.lastUsedExportFolderPath)

        #expect(ExportPanelDefaults(defaults: defaults).startingDirectory?.standardizedFileURL
                == fixed.standardizedFileURL)
    }

    @Test func fixedModeFallsBackToLastUsedWhenThePinnedFolderIsGone() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let last = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: last) }
        let goneFixed = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString)", isDirectory: true)
        defaults.set(ExportFolderMode.fixed.rawValue, forKey: AppSettings.Key.exportFolderMode)
        defaults.set(goneFixed.path, forKey: AppSettings.Key.fixedExportFolderPath)
        defaults.set(last.path, forKey: AppSettings.Key.lastUsedExportFolderPath)

        #expect(ExportPanelDefaults(defaults: defaults).startingDirectory?.standardizedFileURL
                == last.standardizedFileURL)
    }

    @Test func aFileIsNeverReturnedAsAStartingDirectory() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("not-a-folder.txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: dir) }
        defaults.set(file.path, forKey: AppSettings.Key.lastUsedExportFolderPath)

        #expect(ExportPanelDefaults(defaults: defaults).startingDirectory == nil)
    }
}

/// The container default is honored at new-project creation, and only there — an
/// existing project decodes its stored container untouched (issue #87).
@MainActor
struct NewProjectContainerDefaultTests {
    @Test func aNewProjectAdoptsTheConfiguredDefaultContainer() {
        let key = AppSettings.Key.defaultContainer
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(Container.mp4.rawValue, forKey: key)

        let doc = ProjectDocument()
        #expect(doc.project.output.container == .mp4)
    }

    @Test func aNewProjectFallsBackToMkvWithNoConfiguredDefault() {
        let key = AppSettings.Key.defaultContainer
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let doc = ProjectDocument()
        #expect(doc.project.output.container == .mkv)
    }
}
