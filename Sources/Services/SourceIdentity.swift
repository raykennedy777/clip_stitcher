import CryptoKit
import Foundation

/// What a source file *is* for a cache key: its real path, size, modification time to the
/// nanosecond, inode, and a SHA-256 of its first and last 64 KiB. The index cache and the
/// piece cache both key on it, so a source replaced in place — a Rough Cut re-skewed at the
/// same path — changes the key and misses (fail closed). The head/tail hash catches a
/// rewrite that keeps size and mtime (`touch -r`); a change confined to the middle of a
/// file that also keeps both is the one change it cannot see.
struct SourceIdentity: Codable, Hashable, Sendable {
    var path: String
    var size: Int64
    var mtimeNanoseconds: Int64
    var inode: UInt64
    var headTailSHA256: String

    /// How much of each end of the file the content hash reads.
    static let hashedSpan = 64 * 1024

    /// Measures `url`'s identity. Throws when the file cannot be stat'ed or read.
    static func of(_ url: URL) throws -> SourceIdentity {
        let real = url.resolvingSymlinksInPath().path
        var info = stat()
        guard stat(real, &info) == 0 else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: real])
        }
        let size = Int64(info.st_size)
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: real))
        defer { try? handle.close() }
        var hasher = SHA256()
        hasher.update(data: try handle.read(upToCount: hashedSpan) ?? Data())
        let tailStart = max(0, size - Int64(hashedSpan))
        try handle.seek(toOffset: UInt64(tailStart))
        hasher.update(data: try handle.read(upToCount: hashedSpan) ?? Data())
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        return SourceIdentity(path: real, size: size, mtimeNanoseconds: mtime,
                              inode: UInt64(info.st_ino), headTailSHA256: digest)
    }
}

/// The parts of a cache key that come from the running tools, fetched once per process:
/// the whole `-version` text of an ff-tool (its version line and build configuration), and
/// the identity of the running executable. A cache entry made by another build of ffmpeg or
/// of clipstitch never serves this one.
enum CacheFingerprint {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var versions: [String: String] = [:]

    /// SHA-256 of `tool -version`'s output, or of the tool's path when it will not run.
    static func toolVersion(_ tool: URL) async -> String {
        if let known = lock.withLock({ versions[tool.path] }) { return known }
        let output = (try? await ProcessRunner.run(tool, ["-version"]))?.stdout ?? Data(tool.path.utf8)
        let digest = sha256Hex(output)
        lock.withLock { versions[tool.path] = digest }
        return digest
    }

    /// The running executable's path, size and mtime. Facts the index cache stores are
    /// derived by this binary's own parser and detectors, so a rebuild must miss.
    static let executable: String = {
        let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? CommandLine.arguments.first ?? "unknown"
        var info = stat()
        guard stat(path, &info) == 0 else { return path }
        return "\(path)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }()

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// One key from labelled parts. The labels and a separator byte go into the hash, so
    /// two different part lists can never hash the same text.
    static func key(_ parts: [(String, String)]) -> String {
        var hasher = SHA256()
        for (label, value) in parts {
            hasher.update(data: Data(label.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
