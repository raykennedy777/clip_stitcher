import Foundation
import os

enum WorkDirectorySweeper {
    private static let log = Logger(subsystem: "io.github.raykennedy777.clipstitcher",
                                    category: "WorkDirectorySweeper")

    static let workDirectoryPrefixes = ["clipstitcher-export-", "clipstitcher-stitchjob-"]

    // ADR-0035
    static let staleAge: TimeInterval = 24 * 60 * 60

    static let markerName = ".clipstitcher-owner.json"

    struct OwnerMarker: Codable, Equatable, Sendable {
        var pid: Int32
        var startedAt: Double
        var processName: String
    }

    static func claim(_ directory: URL) {
        let marker = OwnerMarker(pid: ProcessInfo.processInfo.processIdentifier,
                                 startedAt: Date().timeIntervalSince1970,
                                 processName: ProcessInfo.processInfo.processName)
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? data.write(to: directory.appendingPathComponent(markerName), options: .atomic)
    }

    enum Owner: Equatable {
        case alive
        case dead
        case unknown
    }

    enum Verdict: Equatable { case keep, delete }

    static func verdict(owner: Owner, age: TimeInterval) -> Verdict {
        switch owner {
        case .alive: return .keep
        case .dead: return .delete
        case .unknown: return age > staleAge ? .delete : .keep
        }
    }

    // ADR-0035
    static func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func owner(of directory: URL) -> Owner {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(markerName)),
              !data.isEmpty,
              let marker = try? JSONDecoder().decode(OwnerMarker.self, from: data),
              marker.pid > 0 else { return .unknown }
        return isRunning(pid: marker.pid) ? .alive : .dead
    }

    struct Outcome: Equatable, Sendable {
        var removed: Int = 0
        var reclaimedBytes: Int64 = 0
    }

    @discardableResult
    static func sweep(in directory: URL = FileManager.default.temporaryDirectory,
                      now: Date = Date()) -> Outcome {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return Outcome() }

        var outcome = Outcome()
        for entry in entries {
            let name = entry.lastPathComponent
            guard workDirectoryPrefixes.contains(where: name.hasPrefix) else { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isDirectory == true else { continue }
            let modified = values.contentModificationDate ?? .distantFuture
            let owner = owner(of: entry)
            guard verdict(owner: owner, age: now.timeIntervalSince(modified)) == .delete else { continue }
            let size = directorySize(entry)
            do {
                try fm.removeItem(at: entry)
                outcome.removed += 1
                outcome.reclaimedBytes += size
                log.notice("""
                    Reclaimed abandoned work directory \(name, privacy: .public) \
                    (\(size / 1_000_000, privacy: .public) MB, \
                    owner \(String(describing: owner), privacy: .public))
                    """)
            } catch {
            }
        }
        if outcome.removed > 0 {
            log.notice("""
                Sweep reclaimed \(outcome.removed, privacy: .public) abandoned work \
                director\(outcome.removed == 1 ? "y" : "ies", privacy: .public), \
                \(outcome.reclaimedBytes / 1_000_000, privacy: .public) MB
                """)
        }
        return outcome
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
