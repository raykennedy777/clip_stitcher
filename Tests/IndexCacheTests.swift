import Testing
import Foundation
@testable import ClipStitcher

/// The index cache's two promises (R2 of the 2026 R16 review): a changed source misses —
/// size, mtime or content — and a hit returns exactly the values that were stored. The
/// plan-level promise (a cached plan equals an uncached one) is in
/// `StitchPipelineIntegrationTests`, where real sources exist.
struct IndexCacheTests {
    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-indexcache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A file larger than both hashed spans together, so a byte in its middle is outside
    /// the head/tail hash.
    private static func makeFile(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("source.bin")
        var bytes = [UInt8](repeating: 0, count: 3 * SourceIdentity.hashedSpan)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31) }
        try Data(bytes).write(to: url)
        return url
    }

    private static func setMtime(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static func facts() -> IndexCache.Facts {
        IndexCache.Facts(
            probe: MediaProbe.Result(
                video: VideoProperties(codec: "hevc", profile: "Main 10", level: "123",
                                       width: 1920, height: 1080, frameRate: "50/1",
                                       pixelFormat: "yuv420p10le", fieldOrder: "progressive",
                                       sampleAspectRatio: "1:1", colorPrimaries: "bt709",
                                       colorTransfer: "bt709", colorRange: "tv"),
                audio: nil, audioTracks: [], duration: 7062.16, containerStart: 1.4,
                videoCodecFrameRate: "50/1"),
            // Values whose decimal text would not round-trip in a lossy store.
            pts: [0.1 + 0.2, 1.0 / 3.0, 1e-300, 7062.1599999999999],
            dts: [0.02, 0.04, 0.06, 0.08],
            keyframeFlags: [true, false, false, true],
            fieldCoded: false,
            damageZones: [DamageZone(start: 12.5, end: 13.25, affectsVideo: true)])
    }

    @Test func aStoredEntryReadsBackExactly() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeFile(in: dir)
        let cache = IndexCache(directory: dir.appendingPathComponent("cache"))
        let identity = try SourceIdentity.of(source)
        #expect(await cache.load(identity) == nil)
        await cache.store(Self.facts(), for: identity)
        let hit = await cache.load(identity)
        #expect(hit == Self.facts())
        #expect(hit?.pts.map(\.bitPattern) == Self.facts().pts.map(\.bitPattern))
    }

    @Test func aChangedSizeMisses() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeFile(in: dir)
        let cache = IndexCache(directory: dir.appendingPathComponent("cache"))
        let before = try SourceIdentity.of(source)
        await cache.store(Self.facts(), for: before)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        let after = try SourceIdentity.of(source)
        #expect(after.size == before.size + 1)
        #expect(await cache.load(after) == nil)
    }

    @Test func aChangedMtimeMisses() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeFile(in: dir)
        let cache = IndexCache(directory: dir.appendingPathComponent("cache"))
        let before = try SourceIdentity.of(source)
        await cache.store(Self.facts(), for: before)
        try Self.setMtime(Date(timeIntervalSince1970: 1_700_000_000), of: source)
        let after = try SourceIdentity.of(source)
        #expect(after.mtimeNanoseconds != before.mtimeNanoseconds)
        #expect(await cache.load(after) == nil)
    }

    /// A rewrite that keeps size and mtime (`touch -r`) is what the content hash is for.
    @Test func aChangedTailWithTheSameSizeAndMtimeMisses() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeFile(in: dir)
        let pinned = Date(timeIntervalSince1970: 1_750_000_000)
        try Self.setMtime(pinned, of: source)
        let cache = IndexCache(directory: dir.appendingPathComponent("cache"))
        let before = try SourceIdentity.of(source)
        await cache.store(Self.facts(), for: before)

        var bytes = try Data(contentsOf: source)
        bytes[bytes.count - 10] ^= 0xFF
        try bytes.write(to: source)
        try Self.setMtime(pinned, of: source)
        let after = try SourceIdentity.of(source)
        #expect(after.size == before.size)
        #expect(after.mtimeNanoseconds == before.mtimeNanoseconds)
        #expect(after.headTailSHA256 != before.headTailSHA256)
        #expect(await cache.load(after) == nil)
    }

    @Test func aChangedHeadChangesTheIdentity() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeFile(in: dir)
        let before = try SourceIdentity.of(source)
        var bytes = try Data(contentsOf: source)
        bytes[5] ^= 0xFF
        try bytes.write(to: source)
        #expect(try SourceIdentity.of(source).headTailSHA256 != before.headTailSHA256)
    }

    /// A damaged entry file is a miss, never an error.
    @Test func anUnreadableEntryMisses() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeFile(in: dir)
        let cacheDir = dir.appendingPathComponent("cache")
        let cache = IndexCache(directory: cacheDir)
        let identity = try SourceIdentity.of(source)
        await cache.store(Self.facts(), for: identity)
        for name in try FileManager.default.contentsOfDirectory(atPath: cacheDir.path) {
            try Data("not a plist".utf8).write(to: cacheDir.appendingPathComponent(name))
        }
        #expect(await cache.load(identity) == nil)
    }
}
