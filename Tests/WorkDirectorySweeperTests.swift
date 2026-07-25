import Testing
import Foundation
@testable import ClipStitcher

/// Exercises the stale work-directory sweep (issue #109): the pure verdict table, the
/// marker round-trip, the liveness probe, and the sweep itself against a synthesized temp
/// tree. The one invariant everything here defends is that a **live** run's directory is
/// never removed — a 49 GB in-progress render once looked exactly like a corpse.
struct WorkDirectorySweeperTests {

    // MARK: the verdict table

    /// A claimed directory is judged by its owner's liveness, never by its age: a 4-hour
    /// render — or a longer batch — must survive a concurrent launch's sweep.
    @Test func aLiveOwnerKeepsItsDirectoryHoweverOld() {
        #expect(WorkDirectorySweeper.verdict(owner: .alive, age: 0) == .keep)
        #expect(WorkDirectorySweeper.verdict(owner: .alive, age: 90 * 24 * 60 * 60) == .keep)
    }

    @Test func aDeadOwnerCondemnsItsDirectoryImmediately() {
        #expect(WorkDirectorySweeper.verdict(owner: .dead, age: 0) == .delete)
    }

    /// Unclaimed directories — the integration tests' `clipstitcher-stitchjob-*` among them —
    /// fall to the age gate. Note the strict boundary: exactly 24 h old is still kept.
    @Test func anUnclaimedDirectoryIsJudgedByAge() {
        let day = WorkDirectorySweeper.staleAge
        #expect(WorkDirectorySweeper.verdict(owner: .unknown, age: 0) == .keep)
        #expect(WorkDirectorySweeper.verdict(owner: .unknown, age: day) == .keep)
        #expect(WorkDirectorySweeper.verdict(owner: .unknown, age: day + 1) == .delete)
    }

    // MARK: liveness

    /// `kill(pid, 0)` asks without signalling. This process is alive by definition; a pid
    /// that has exited is not. And a corrupt marker's non-positive pid is never even asked
    /// about — `kill(0, …)` would address our own process group.
    @Test func livenessFollowsTheRealProcessAndNeverSignalsAGroup() async throws {
        #expect(WorkDirectorySweeper.isRunning(pid: ProcessInfo.processInfo.processIdentifier))
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        #expect(!WorkDirectorySweeper.isRunning(pid: exited.processIdentifier))
        #expect(!WorkDirectorySweeper.isRunning(pid: 0))
        #expect(!WorkDirectorySweeper.isRunning(pid: -1))
    }

    // MARK: the marker

    /// A claim names the running process, so the sweep reads its own directory as alive.
    @Test func claimingADirectoryMarksItAliveForThisProcess() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WorkDirectorySweeper.owner(of: dir) == .unknown)   // nothing written yet
        WorkDirectorySweeper.claim(dir)
        #expect(WorkDirectorySweeper.owner(of: dir) == .alive)
        let data = try Data(contentsOf: dir.appendingPathComponent(WorkDirectorySweeper.markerName))
        let marker = try JSONDecoder().decode(WorkDirectorySweeper.OwnerMarker.self, from: data)
        #expect(marker.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(marker.processName == ProcessInfo.processInfo.processName)
    }

    /// A half-written marker reads as **unknown**, not dead — a torn file must never license
    /// a deletion, so it falls to the age gate like an unclaimed directory. Same for an empty
    /// one, and for a marker whose pid is nonsense.
    @Test func aTornOrNonsenseMarkerReadsAsUnknownNotDead() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent(WorkDirectorySweeper.markerName)
        for content in ["", "{\"pid\":", "{\"pid\":0,\"startedAt\":0,\"processName\":\"x\"}"] {
            try Data(content.utf8).write(to: marker)
            #expect(WorkDirectorySweeper.owner(of: dir) == .unknown)
        }
    }

    // MARK: the sweep

    /// The whole table, on a real tree: a live claim survives however old, a dead claim goes,
    /// an unclaimed corpse goes on age, a fresh unclaimed directory (the microsecond window
    /// between `createDirectory` and `claim`, and every other instance launching right now)
    /// survives, and anything outside the known prefixes is not the sweep's business.
    @Test func theSweepRemovesOnlyAbandonedWorkDirectories() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let now = Date()
        let ancient = now.addingTimeInterval(-40 * 60 * 60)

        // A live run, backdated well past the age gate: liveness beats age.
        let live = try Self.makeChild(root, "clipstitcher-export-live", modified: ancient)
        WorkDirectorySweeper.claim(live)
        // A killed run: its marker names a process that has exited.
        let dead = try Self.makeChild(root, "clipstitcher-export-dead", modified: now)
        try Self.claimByAnExitedProcess(dead)
        // Unclaimed: the test-fixture shape, judged by age alone.
        let oldUnclaimed = try Self.makeChild(root, "clipstitcher-stitchjob-old", modified: ancient)
        let freshUnclaimed = try Self.makeChild(root, "clipstitcher-export-fresh", modified: now)
        // Out of scope: another prefix (Clip Doctor's, which is never claimed), a file that
        // merely matches, and a symlink that must not be followed.
        let doctor = try Self.makeChild(root, "clipstitcher-doctor-old", modified: ancient)
        let file = root.appendingPathComponent("clipstitcher-export-notadir")
        try Data("x".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: ancient], ofItemAtPath: file.path)
        let link = root.appendingPathComponent("clipstitcher-export-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: live)

        // The dead run's payload is what the reclaim figure counts.
        try Data(repeating: 0x41, count: 4096).write(to: dead.appendingPathComponent("piece.ts"))

        let outcome = WorkDirectorySweeper.sweep(in: root, now: now)

        #expect(outcome.removed == 2)                       // the dead claim + the old corpse
        #expect(outcome.reclaimedBytes >= 4096)
        #expect(!fm.fileExists(atPath: dead.path))
        #expect(!fm.fileExists(atPath: oldUnclaimed.path))
        #expect(fm.fileExists(atPath: live.path))
        #expect(fm.fileExists(atPath: freshUnclaimed.path))
        #expect(fm.fileExists(atPath: doctor.path))
        #expect(fm.fileExists(atPath: file.path))
        // The symlink is skipped, and — the point of not following it — its target survives.
        #expect((try? link.checkResourceIsReachable()) == true)
    }

    /// Sweeping is best-effort: an unreadable root, or a second sweep over ground the first
    /// already cleared, is a no-op rather than a failure. A launch can never be failed by it.
    @Test func theSweepIsHarmlessWhenThereIsNothingToDo() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = try Self.makeChild(root, "clipstitcher-export-stale",
                                       modified: Date().addingTimeInterval(-40 * 60 * 60))
        #expect(WorkDirectorySweeper.sweep(in: root).removed == 1)
        #expect(WorkDirectorySweeper.sweep(in: root) == WorkDirectorySweeper.Outcome())
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let missing = root.appendingPathComponent("no-such-directory")
        #expect(WorkDirectorySweeper.sweep(in: missing) == WorkDirectorySweeper.Outcome())
    }

    // MARK: helpers

    private static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-sweeptest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeChild(_ root: URL, _ name: String, modified: Date) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: dir.path)
        return dir
    }

    /// A marker naming a process that really has exited — a killed run's directory. Uses a
    /// genuinely reaped pid rather than an invented number, so the liveness probe is the thing
    /// under test and not a guess about which pids are free.
    private static func claimByAnExitedProcess(_ directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let marker = WorkDirectorySweeper.OwnerMarker(
            pid: process.processIdentifier, startedAt: Date().timeIntervalSince1970,
            processName: "clipstitch")
        try JSONEncoder().encode(marker)
            .write(to: directory.appendingPathComponent(WorkDirectorySweeper.markerName))
    }
}
