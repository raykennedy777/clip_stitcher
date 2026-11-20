import Foundation

struct IndexCache {
    static let schema = 1

    let directory: URL

    private struct Entry: Codable {
        var schema: Int
        var identity: SourceIdentity
        var probe: MediaProbe.Result
        var pts: Data
        var dts: Data
        var keyframes: Data
        var fieldCoded: Bool
        var damageZones: [DamageZone]
    }

    struct Facts: Equatable {
        var probe: MediaProbe.Result
        var pts: [Double]
        var dts: [Double]
        var keyframeFlags: [Bool]
        var fieldCoded: Bool
        var damageZones: [DamageZone]

        var index: FrameIndex { FrameIndex(pts: pts, dts: dts, keyframeFlags: keyframeFlags) }
    }

    func key(for identity: SourceIdentity) async -> String {
        var ffprobe = "none", ffmpeg = "none"
        if let tool = try? FFTools.ffprobeURL() { ffprobe = await CacheFingerprint.toolVersion(tool) }
        if let tool = try? FFTools.ffmpegURL() { ffmpeg = await CacheFingerprint.toolVersion(tool) }
        return CacheFingerprint.key([
            ("schema", String(Self.schema)),
            ("path", identity.path),
            ("size", String(identity.size)),
            ("mtime", String(identity.mtimeNanoseconds)),
            ("inode", String(identity.inode)),
            ("headTail", identity.headTailSHA256),
            ("ffprobe", ffprobe),
            ("ffmpeg", ffmpeg),
            ("executable", CacheFingerprint.executable),
        ])
    }

    private func entryURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).index.plist")
    }

    func load(_ identity: SourceIdentity) async -> Facts? {
        let url = entryURL(await key(for: identity))
        guard let data = try? Data(contentsOf: url),
              let entry = try? PropertyListDecoder().decode(Entry.self, from: data),
              entry.schema == Self.schema, entry.identity == identity else { return nil }
        let pts: [Double] = Self.unpack(entry.pts)
        let dts: [Double] = Self.unpack(entry.dts)
        let keyframes: [UInt8] = Self.unpack(entry.keyframes)
        guard dts.count == pts.count, keyframes.count == pts.count else { return nil }
        return Facts(probe: entry.probe, pts: pts, dts: dts,
                     keyframeFlags: keyframes.map { $0 != 0 },
                     fieldCoded: entry.fieldCoded, damageZones: entry.damageZones)
    }

    func store(_ facts: Facts, for identity: SourceIdentity) async {
        let entry = Entry(schema: Self.schema, identity: identity, probe: facts.probe,
                          pts: Self.pack(facts.pts), dts: Self.pack(facts.dts),
                          keyframes: Self.pack(facts.keyframeFlags.map { $0 ? UInt8(1) : 0 }),
                          fieldCoded: facts.fieldCoded, damageZones: facts.damageZones)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(entry) else { return }
        let url = entryURL(await key(for: identity))
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard (try? data.write(to: temp)) != nil else { return }
        if rename(temp.path, url.path) != 0 { try? fm.removeItem(at: temp) }
    }

    static func pack<T>(_ values: [T]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpack<T: Numeric>(_ data: Data) -> [T] {
        guard data.count % MemoryLayout<T>.stride == 0 else { return [] }
        var values = [T](repeating: 0, count: data.count / MemoryLayout<T>.stride)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }
}
