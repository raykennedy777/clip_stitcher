import Testing
import Foundation
@testable import ClipStitcher

/// The piece cache's key and store (R1 of the 2026 R16 review), without an encoder. The
/// render-level promises — a warm render is stream-identical to a cold one, and an edit
/// re-encodes only the pieces it touches — are in `StitchPipelineIntegrationTests`.
struct PieceCacheTests {
    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-piececache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeSource(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("source.mkv")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) }).write(to: url)
        return url
    }

    /// `/usr/bin/true` stands in for ffmpeg: its `-version` output is the fingerprint.
    private static let tool = URL(fileURLWithPath: "/usr/bin/true")

    private static func args(source: URL, output: URL, crf: String = "18") -> [String] {
        ["-v", "error", "-ss", "1.000", "-i", source.path,
         "-vf", "select='between(n\\,5\\,11)',setpts=PTS-STARTPTS",
         "-c:v", "libx265", "-crf", crf, "-frames:v", "7", "-an", output.path]
    }

    private static let segment = PlannedSegment(kind: .reEncode, range: 5..<12)

    private func key(_ cache: PieceCache, source: URL, output: URL, crf: String = "18",
                     segment: PlannedSegment? = PieceCacheTests.segment) async -> String? {
        await cache.key(source: source, arguments: Self.args(source: source, output: output, crf: crf),
                        output: output, segment: segment, ffmpeg: Self.tool)
    }

    /// The output piece's path is not part of the key: a clip that moves to another index,
    /// in another render's work directory, still hits.
    @Test func theKeyIgnoresTheOutputPath() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeSource(in: dir)
        let cache = PieceCache(directory: dir.appendingPathComponent("pieces"))
        let a = await key(cache, source: source, output: URL(fileURLWithPath: "/tmp/w1/c0_s0_re.mkv"))
        let b = await key(cache, source: source, output: URL(fileURLWithPath: "/tmp/w2/c7_s3_re.mkv"))
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func oneChangedArgumentChangesTheKey() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeSource(in: dir)
        let cache = PieceCache(directory: dir.appendingPathComponent("pieces"))
        let out = URL(fileURLWithPath: "/tmp/w/c0_s0_re.mkv")
        #expect(await key(cache, source: source, output: out, crf: "18")
                != key(cache, source: source, output: out, crf: "21"))
    }

    @Test func aChangedSegmentChangesTheKey() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeSource(in: dir)
        let cache = PieceCache(directory: dir.appendingPathComponent("pieces"))
        let out = URL(fileURLWithPath: "/tmp/w/c0_s0_re.mkv")
        let moved = PlannedSegment(kind: .reEncode, range: 5..<13)
        let repaired = PlannedSegment(kind: .reEncode, range: 5..<12,
                                      damage: [DamageZone(start: 0.2, end: 0.3, affectsVideo: true)])
        let base = await key(cache, source: source, output: out)
        #expect(await key(cache, source: source, output: out, segment: moved) != base)
        #expect(await key(cache, source: source, output: out, segment: repaired) != base)
        #expect(await key(cache, source: source, output: out, segment: nil) != base)
    }

    /// One changed source byte is a different source. A fresh cache object measures the
    /// identity again (one object serves one render, and memoises it).
    @Test func aChangedSourceChangesTheKey() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeSource(in: dir)
        let out = URL(fileURLWithPath: "/tmp/w/c0_s0_re.mkv")
        let before = await key(PieceCache(directory: dir), source: source, output: out)
        var bytes = try Data(contentsOf: source)
        bytes[100] ^= 0xFF
        try bytes.write(to: source)
        let after = await key(PieceCache(directory: dir), source: source, output: out)
        #expect(before != after)
    }

    @Test func aStoredPieceFetchesByteIdentical() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = PieceCache(directory: dir.appendingPathComponent("pieces"))
        let piece = dir.appendingPathComponent("c0_s0_re.mkv")
        let bytes = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try bytes.write(to: piece)

        let fetched = dir.appendingPathComponent("work/c3_s1_re.mkv")
        try FileManager.default.createDirectory(at: fetched.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        #expect(!cache.fetch("k1", to: fetched))
        cache.store("k1", from: piece)
        #expect(cache.fetch("k1", to: fetched))
        #expect(try Data(contentsOf: fetched) == bytes)
        #expect(cache.hits == 1)
        #expect(cache.misses == 1)

        cache.evict("k1", ext: "mkv")
        #expect(!cache.fetch("k1", to: dir.appendingPathComponent("again.mkv")))
    }
}
