import Foundation

/// Test-only bypass for the modal file panels (issue #37). When the app is
/// launched with `CLIPSTITCHER_AUTOMATION=1`, the export save panel and the
/// import/relink open panels are skipped and their paths come from companion
/// variables instead — so automated verification (see
/// `docs/agents/ui-automation.md`) can run export → inspect → re-import without
/// driving a system dialog. Without the marker `current` is nil and every
/// call site falls through to its normal panel, unchanged.
struct AutomationOverrides {
    /// The marker that arms the bypass; must be exactly "1".
    static let markerVariable = "CLIPSTITCHER_AUTOMATION"
    /// Export destination: a file path in connect mode, a folder in separate mode.
    static let exportDestinationVariable = "CLIPSTITCHER_EXPORT_DEST"
    /// Add File sources — newline-separated paths, imported in order.
    static let importSourcesVariable = "CLIPSTITCHER_IMPORT_SOURCE"
    /// Relink source — a single path.
    static let relinkSourceVariable = "CLIPSTITCHER_RELINK_SOURCE"

    let exportDestination: URL?
    let importSources: [URL]
    let relinkSource: URL?

    /// Nil unless the marker is set — the bypass is unreachable on a normal
    /// launch. A companion variable left unset leaves that flow on its panel.
    static func fromEnvironment(_ env: [String: String]) -> AutomationOverrides? {
        guard env[markerVariable] == "1" else { return nil }
        return AutomationOverrides(
            exportDestination: env[exportDestinationVariable].flatMap(fileURL),
            importSources: (env[importSourcesVariable] ?? "")
                .split(separator: "\n").compactMap { fileURL(String($0)) },
            relinkSource: env[relinkSourceVariable].flatMap(fileURL)
        )
    }

    private static func fileURL(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
    }

    /// The process-wide overrides, read once — the environment can't change
    /// after launch.
    static let current = fromEnvironment(ProcessInfo.processInfo.environment)
}
