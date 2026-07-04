import Testing
import Foundation
@testable import ClipStitcher

/// Model-level coverage of the Clip Doctor destination validation that runs on pick
/// (issue #83): a destination that denotes the source, or one whose folder can't be
/// written to, is caught before Repair — not as a post-click failure. Exercises the pure
/// `ClipDoctorModel.destinationIssue` directly (no ProjectDocument / sheet needed).
struct ClipDoctorDestinationTests {

    /// Makes a throwaway directory under the temp dir; the caller removes it.
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("doctorDest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A destination equal to the source is refused — a run would truncate the capture.
    @Test func destinationEqualToSourceIsSourceCollision() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("clip.ts")
        FileManager.default.createFile(atPath: source.path, contents: Data([0, 1, 2]))

        let issue = ClipDoctorModel.destinationIssue(destination: source, source: source)
        #expect(issue == .isSource)
    }

    /// A symlink to the source resolves to the same file, so it's caught too (reuses
    /// `ExportEngine.denotesSameFile`, which resolves symlinks — landed with #77).
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

    /// A distinct sibling in a writable folder validates clean.
    @Test func distinctWritableDestinationHasNoIssue() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("clip.ts")
        FileManager.default.createFile(atPath: source.path, contents: Data([0, 1, 2]))
        let dest = dir.appendingPathComponent("clip_repaired.ts")

        #expect(ClipDoctorModel.destinationIssue(destination: dest, source: source) == nil)
    }

    /// A destination whose folder isn't writable is refused up front — the mux would
    /// otherwise only fail at the end. The source lives elsewhere (no collision), so the
    /// unwritable-folder branch is what fires.
    @Test func unwritableDestinationFolderIsRefused() throws {
        let sourceDir = try makeTempDir()
        let readOnlyDir = try makeTempDir()
        defer {
            // Restore write so cleanup can remove it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDir.path)
            try? FileManager.default.removeItem(at: readOnlyDir)
            try? FileManager.default.removeItem(at: sourceDir)
        }
        let source = sourceDir.appendingPathComponent("clip.ts")
        FileManager.default.createFile(atPath: source.path, contents: Data([0, 1, 2]))
        // r-x for owner: can traverse, cannot create files.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDir.path)
        let dest = readOnlyDir.appendingPathComponent("clip_repaired.ts")

        #expect(ClipDoctorModel.destinationIssue(destination: dest, source: source) == .unwritableFolder)
    }
}
