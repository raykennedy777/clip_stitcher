import Foundation

/// Where the export / Clip Doctor / (future snapshot #89) save panels start.
/// `lastUsed` reopens on the folder of the user's previous pick; `fixed` pins a
/// folder the user chose in Settings (issue #87).
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

/// App-wide preferences backed by `UserDefaults` (issue #87). The `@AppStorage`
/// keys the Settings window binds to live here so the Settings UI, the panel-defaults
/// helper, and the new-project container default all read the same strings.
///
/// The app is not sandboxed (no entitlements, no `com.apple.security.app-sandbox`),
/// so the fixed export folder is stored as a plain path — no security-scoped bookmark
/// needed.
enum AppSettings {
    enum Key {
        static let exportFolderMode = "exportFolderMode"
        static let fixedExportFolderPath = "fixedExportFolderPath"
        static let lastUsedExportFolderPath = "lastUsedExportFolderPath"
        static let defaultContainer = "defaultContainer"
    }

    /// The container a **new** project starts with (issue #87). Honored at project
    /// creation only; a per-project change and an existing project's saved value are
    /// untouched. An unknown or missing raw value falls back to the historical MKV
    /// default (issue #10) rather than trapping — so a stale/hand-edited default is
    /// safe.
    static func defaultContainer(_ defaults: UserDefaults = .standard) -> Container {
        guard let raw = defaults.string(forKey: Key.defaultContainer),
              let container = Container(rawValue: raw) else { return .mkv }
        return container
    }
}

/// The single mechanism every export-destination save/open panel threads for its
/// starting directory and its "remember the last choice" bookkeeping (issue #87) —
/// so the export panel, the Clip Doctor "Change…" panel, and the future snapshot
/// panel (#89) all behave identically instead of each carrying its own copy.
///
/// `startingDirectory` is the folder the panel should open on, or `nil` when the
/// setting has nothing to offer (last-used mode with no prior pick, or a fixed
/// folder that has gone missing) — the caller then falls back to its own context
/// default (e.g. the target clip's folder). Recording a pick is a no-op cost the
/// caller always pays after a successful choice.
struct ExportPanelDefaults {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var mode: ExportFolderMode {
        defaults.string(forKey: AppSettings.Key.exportFolderMode)
            .flatMap(ExportFolderMode.init(rawValue:)) ?? .lastUsed
    }

    /// The folder the next panel should open on, or `nil` to leave the caller's own
    /// fallback in charge. In `fixed` mode the pinned folder wins when it still exists;
    /// if it's gone we fall through to the last-used folder rather than dropping the
    /// user somewhere surprising. In `lastUsed` mode it's simply the recorded folder.
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

    /// Records the folder a just-picked **file** lives in (save panels).
    func recordChosenFile(_ fileURL: URL) {
        store(folder: fileURL.deletingLastPathComponent())
    }

    /// Records a just-picked **folder** (the Separate-mode export open panel).
    func recordChosenFolder(_ folderURL: URL) {
        store(folder: folderURL)
    }

    /// Always kept current, even in `fixed` mode — switching back to "last choice"
    /// then resumes where the user actually was, and it never overrides a fixed folder
    /// while that mode is on.
    private func store(folder: URL) {
        defaults.set(folder.path, forKey: AppSettings.Key.lastUsedExportFolderPath)
    }
}
