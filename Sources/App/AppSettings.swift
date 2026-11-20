import Foundation

enum ExportFolderMode: String, CaseIterable, Identifiable {
    case lastUsed
    case fixed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lastUsed: return "Remember my last choice"
        case .fixed: return "Always start in a fixed folder"
        }
    }
}

enum AppSettings {
    enum Key {
        static let exportFolderMode = "exportFolderMode"
        static let fixedExportFolderPath = "fixedExportFolderPath"
        static let lastUsedExportFolderPath = "lastUsedExportFolderPath"
        static let defaultContainer = "defaultContainer"
    }

    static func defaultContainer(_ defaults: UserDefaults = .standard) -> Container {
        guard let raw = defaults.string(forKey: Key.defaultContainer),
              let container = Container(rawValue: raw) else { return .mkv }
        return container
    }
}

struct ExportPanelDefaults {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var mode: ExportFolderMode {
        defaults.string(forKey: AppSettings.Key.exportFolderMode)
            .flatMap(ExportFolderMode.init(rawValue:)) ?? .lastUsed
    }

    var startingDirectory: URL? {
        if mode == .fixed, let fixed = existingDirectory(
            forKey: AppSettings.Key.fixedExportFolderPath) {
            return fixed
        }
        return existingDirectory(forKey: AppSettings.Key.lastUsedExportFolderPath)
    }

    private func existingDirectory(forKey key: String) -> URL? {
        guard let path = defaults.string(forKey: key), !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func recordChosenFile(_ fileURL: URL) {
        store(folder: fileURL.deletingLastPathComponent())
    }

    func recordChosenFolder(_ folderURL: URL) {
        store(folder: folderURL)
    }

    private func store(folder: URL) {
        defaults.set(folder.path, forKey: AppSettings.Key.lastUsedExportFolderPath)
    }
}
