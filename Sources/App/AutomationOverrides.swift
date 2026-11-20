import Foundation

struct AutomationOverrides {
    static let markerVariable = "CLIPSTITCHER_AUTOMATION"
    static let exportDestinationVariable = "CLIPSTITCHER_EXPORT_DEST"
    static let importSourcesVariable = "CLIPSTITCHER_IMPORT_SOURCE"
    static let relinkSourceVariable = "CLIPSTITCHER_RELINK_SOURCE"

    let exportDestination: URL?
    let importSources: [URL]
    let relinkSource: URL?

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

    static let current = fromEnvironment(ProcessInfo.processInfo.environment)
}
