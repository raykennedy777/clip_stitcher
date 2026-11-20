import CryptoKit
import Foundation

struct SourceIdentity: Codable, Hashable, Sendable {
    var path: String
    var size: Int64
    var mtimeNanoseconds: Int64
    var inode: UInt64
    var headTailSHA256: String

    static let hashedSpan = 64 * 1024

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

enum CacheFingerprint {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var versions: [String: String] = [:]

    static func toolVersion(_ tool: URL) async -> String {
        if let known = lock.withLock({ versions[tool.path] }) { return known }
        let output = (try? await ProcessRunner.run(tool, ["-version"]))?.stdout ?? Data(tool.path.utf8)
        let digest = sha256Hex(output)
        lock.withLock { versions[tool.path] = digest }
        return digest
    }

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
