import Testing
import Foundation
@testable import ClipStitcher

struct WorkDirectorySweeperTests {
    @Test func aLiveOwnerKeepsItsDirectoryHoweverOld() {
        #expect(WorkDirectorySweeper.verdict(owner: .alive, age: 0) == .keep)
        #expect(WorkDirectorySweeper.verdict(owner: .alive, age: 90 * 24 * 60 * 60) == .keep)
    }

    @Test func aDeadOwnerCondemnsItsDirectoryImmediately() {
        #expect(WorkDirectorySweeper.verdict(owner: .dead, age: 0) == .delete)
    }

    @Test func anUnclaimedDirectoryIsJudgedByAge() {
        let day = WorkDirectorySweeper.staleAge
        #expect(WorkDirectorySweeper.verdict(owner: .unknown, age: 0) == .keep)
        #expect(WorkDirectorySweeper.verdict(owner: .unknown, age: day) == .keep)
        #expect(WorkDirectorySweeper.verdict(owner: .unknown, age: day + 1) == .delete)
    }

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

    @Test func claimingADirectoryMarksItAliveForThisProcess() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WorkDirectorySweeper.owner(of: dir) == .unknown)
        WorkDirectorySweeper.claim(dir)
        #expect(WorkDirectorySweeper.owner(of: dir) == .alive)
        let data = try Data(contentsOf: dir.appendingPathComponent(WorkDirectorySweeper.markerName))
        let marker = try JSONDecoder().decode(WorkDirectorySweeper.OwnerMarker.self, from: data)
        #expect(marker.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(marker.processName == ProcessInfo.processInfo.processName)
    }

    @Test func aTornOrNonsenseMarkerReadsAsUnknownNotDead() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent(WorkDirectorySweeper.markerName)
        for content in ["", "{\"pid\":", "{\"pid\":0,\"startedAt\":0,\"processName\":\"x\"}"] {
            try Data(content.utf8).write(to: marker)
            #expect(WorkDirectorySweeper.owner(of: dir) == .unknown)
        }
    }

    @Test func theSweepRemovesOnlyAbandonedWorkDirectories() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let now = Date()
        let ancient = now.addingTimeInterval(-40 * 60 * 60)

        let live = try Self.makeChild(root, "clipstitcher-export-live", modified: ancient)
        WorkDirectorySweeper.claim(live)
        let dead = try Self.makeChild(root, "clipstitcher-export-dead", modified: now)
        try Self.claimByAnExitedProcess(dead)
        let oldUnclaimed = try Self.makeChild(root, "clipstitcher-stitchjob-old", modified: ancient)
        let freshUnclaimed = try Self.makeChild(root, "clipstitcher-export-fresh", modified: now)
        let doctor = try Self.makeChild(root, "clipstitcher-doctor-old", modified: ancient)
        let file = root.appendingPathComponent("clipstitcher-export-notadir")
        try Data("x".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: ancient], ofItemAtPath: file.path)
        let link = root.appendingPathComponent("clipstitcher-export-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: live)

        try Data(repeating: 0x41, count: 4096).write(to: dead.appendingPathComponent("piece.ts"))

        let outcome = WorkDirectorySweeper.sweep(in: root, now: now)

        #expect(outcome.removed == 2)
        #expect(outcome.reclaimedBytes >= 4096)
        #expect(!fm.fileExists(atPath: dead.path))
        #expect(!fm.fileExists(atPath: oldUnclaimed.path))
        #expect(fm.fileExists(atPath: live.path))
        #expect(fm.fileExists(atPath: freshUnclaimed.path))
        #expect(fm.fileExists(atPath: doctor.path))
        #expect(fm.fileExists(atPath: file.path))
        #expect((try? link.checkResourceIsReachable()) == true)
    }

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
