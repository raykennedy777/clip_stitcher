import Testing
import Foundation
@testable import ClipStitcher

struct ClipDoctorDestinationTests {
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("doctorDest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func destinationEqualToSourceIsSourceCollision() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("clip.ts")
        FileManager.default.createFile(atPath: source.path, contents: Data([0, 1, 2]))

        let issue = ClipDoctorModel.destinationIssue(destination: source, source: source)
        #expect(issue == .isSource)
    }

    @Test func symlinkToSourceIsSourceCollision() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("clip.ts")
        FileManager.default.createFile(atPath: source.path, contents: Data([0, 1, 2]))
        let link = dir.appendingPathComponent("clip_link.ts")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)

        let issue = ClipDoctorModel.destinationIssue(destination: link, source: source)
        #expect(issue == .isSource)
    }

    @Test func distinctWritableDestinationHasNoIssue() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("clip.ts")
        FileManager.default.createFile(atPath: source.path, contents: Data([0, 1, 2]))
        let dest = dir.appendingPathComponent("clip_repaired.ts")

        #expect(ClipDoctorModel.destinationIssue(destination: dest, source: source) == nil)
    }

    @Test func unwritableDestinationFolderIsRefused() throws {
        let sourceDir = try makeTempDir()
        let readOnlyDir = try makeTempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDir.path)
            try? FileManager.default.removeItem(at: readOnlyDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }
        let source = sourceDir.appendingPathComponent("clip.ts")
        FileManager.default.createFile(atPath: source.path, contents: Data([0, 1, 2]))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDir.path)
        let dest = readOnlyDir.appendingPathComponent("clip_repaired.ts")

        #expect(ClipDoctorModel.destinationIssue(destination: dest, source: source) == .unwritableFolder)
    }
}
