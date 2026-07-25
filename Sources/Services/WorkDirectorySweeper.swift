import Foundation
import os

/// Reclaims the temp work directories a **hard kill** leaves behind (issue #109).
///
/// `ExportEngine.runExport` cleans its work directory in a `defer`, which covers every
/// ordinary exit — a normal return, a thrown error, a cancel. What it cannot cover is a
/// force-quit, a `^C`/SIGTERM on the `clipstitch` CLI, or a crash: no `defer` runs, and the
/// directory stays. On a 4h36m source that is tens of gigabytes per abandoned run — six of
/// them accumulated over two days of rendering, one 13 GB — so the fix has to be a sweep,
/// not better teardown. This changes no teardown.
///
/// The whole difficulty is telling a corpse from a **live** run: concurrent exports are
/// normal (the app and a CLI side by side), and while investigating #107 a 49 GB directory
/// that looked exactly like the stale ones was an in-progress multi-hour render. So every
/// run *claims* its directory with a marker naming the owning process, and the sweep reads
/// it (see `verdict`). Liveness always beats age — a 4-hour render, or a longer batch, must
/// survive a launch — and every uncertainty resolves to *keep*: the cost of guessing wrong
/// one way is a leak reclaimed by a later sweep, the other way is a destroyed job.
enum WorkDirectorySweeper {
    private static let log = Logger(subsystem: "io.github.raykennedy777.clipstitcher",
                                    category: "WorkDirectorySweeper")

    /// The work-directory name prefixes the sweep owns: the export engine's own directories
    /// and the stitch-pipeline integration tests' (which carry no marker, so the age gate
    /// governs them). Clip Doctor's `clipstitcher-doctor-*` is deliberately out of scope —
    /// it is not claimed, so a sweep must not judge it.
    static let workDirectoryPrefixes = ["clipstitcher-export-", "clipstitcher-stitchjob-"]

    /// How long an **unclaimed** directory must sit untouched before it counts as a corpse.
    /// Only ever applied to directories with no readable marker — a claimed one is judged by
    /// its owner's liveness however old it is.
    static let staleAge: TimeInterval = 24 * 60 * 60

    /// The marker file a run writes into its own work directory. Hidden, and named so it
    /// can't collide with a piece (`c<N>_s<n>_…`).
    static let markerName = ".clipstitcher-owner.json"

    /// Who owns a work directory. `startedAt` and `processName` are for diagnosis — reading
    /// a leaked directory should say *what* left it — while `pid` is the only field the
    /// verdict consults.
    struct OwnerMarker: Codable, Equatable, Sendable {
        var pid: Int32
        var startedAt: Double
        var processName: String
    }

    // MARK: - Claiming

    /// Claims `directory` for this process. **Call immediately after creating it**, before
    /// any piece is written: that keeps the unmarked window microseconds wide, and even
    /// inside it the directory is both marker-less *and* newer than `staleAge`, so a
    /// concurrent launch's sweep keeps it either way. Multiple instances starting at once
    /// therefore can't delete each other's work.
    ///
    /// Best-effort by design: a marker that can't be written leaves the directory on the age
    /// gate — a possible late reclaim — never a failed export.
    static func claim(_ directory: URL) {
        let marker = OwnerMarker(pid: ProcessInfo.processInfo.processIdentifier,
                                 startedAt: Date().timeIntervalSince1970,
                                 processName: ProcessInfo.processInfo.processName)
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? data.write(to: directory.appendingPathComponent(markerName), options: .atomic)
    }

    // MARK: - The decision

    /// What a work directory's marker says about its owner.
    enum Owner: Equatable {
        /// A marker naming a process that is still running.
        case alive
        /// A marker naming a process that has exited.
        case dead
        /// No marker, or one that is missing, empty or unparseable — including a
        /// half-written one. Never read as "dead": a torn marker must not license a
        /// deletion, so these fall to the age gate.
        case unknown
    }

    enum Verdict: Equatable { case keep, delete }

    /// The sweep's rule, exactly as decided on #109:
    ///
    /// | directory state | action |
    /// |---|---|
    /// | marker present, PID alive | keep — even if old. Never delete a live run. |
    /// | marker present, PID dead | delete |
    /// | no marker, untouched > 24 h | delete |
    /// | no marker, untouched ≤ 24 h | keep |
    ///
    /// PID reuse can make a dead owner look alive; that fails **safe** — a leak, not a
    /// deletion — and the directory is reclaimed by a later sweep once the recycled PID exits.
    static func verdict(owner: Owner, age: TimeInterval) -> Verdict {
        switch owner {
        case .alive: return .keep
        case .dead: return .delete
        case .unknown: return age > staleAge ? .delete : .keep
        }
    }

    /// Whether the process a marker names is still running. `kill(pid, 0)` sends no signal —
    /// it only asks. `EPERM` counts as alive (the process exists; it just isn't ours), and a
    /// non-positive pid is *not* asked about at all: `kill(0, …)` addresses our own process
    /// group and `kill(-1, …)` every process we may signal, so a corrupt marker must never
    /// reach that call.
    static func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The owner of a work directory as its marker file reports it. An absent, empty,
    /// truncated or otherwise unparseable marker is `.unknown`, never `.dead`.
    static func owner(of directory: URL) -> Owner {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(markerName)),
              !data.isEmpty,
              let marker = try? JSONDecoder().decode(OwnerMarker.self, from: data),
              marker.pid > 0 else { return .unknown }
        return isRunning(pid: marker.pid) ? .alive : .dead
    }

    // MARK: - The sweep

    struct Outcome: Equatable, Sendable {
        var removed: Int = 0
        var reclaimedBytes: Int64 = 0
    }

    /// Sweeps `directory` (the temp directory in production) for abandoned work directories
    /// and removes them, returning what was reclaimed. Best-effort throughout, like the
    /// teardown it backstops: it can never throw, and it can never fail a launch.
    ///
    /// Two concurrent sweeps can pick the same *stale* directory; the loser's removal simply
    /// fails on an already-gone path, which is why the error is tolerated rather than guarded
    /// against. Symlinks are not followed and non-directories matching the prefixes are
    /// skipped — the sweep deletes recursively, so it only ever acts on a real directory it
    /// recognises.
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
            // No modification date means no age to judge by, so only a dead owner condemns
            // it: `.distantFuture`'s age is negative and the age gate keeps it.
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
                // Already gone (a concurrent sweep won) or not ours to remove — either way
                // there is nothing to do and nothing worth reporting.
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

    /// The bytes a directory tree occupies, for the reclaim figure. Best-effort: an
    /// unreadable entry contributes 0 rather than aborting the sweep, and the number is only
    /// ever logged.
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
