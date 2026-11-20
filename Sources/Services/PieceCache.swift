import Foundation

final class PieceCache: @unchecked Sendable {
    static let schema = 1

    let directory: URL
    private let lock = NSLock()
    private var identities: [String: SourceIdentity] = [:]
    private var counters = (hits: 0, misses: 0)

    init(directory: URL) {
        self.directory = directory
    }

    var hits: Int { lock.withLock { counters.hits } }
    var misses: Int { lock.withLock { counters.misses } }

    static let outputPlaceholder = "<piece>"

    func key(source: URL, arguments: [String], output: URL,
             segment: PlannedSegment?, ffmpeg: URL) async -> String? {
        guard let identity = identity(of: source) else { return nil }
        let version = await CacheFingerprint.toolVersion(ffmpeg)
        let args = arguments.map { $0 == output.path ? Self.outputPlaceholder : $0 }
        let segmentText = segment.map(Self.segmentText) ?? "conform"
        return CacheFingerprint.key([
            ("schema", String(Self.schema)),
            ("path", identity.path),
            ("size", String(identity.size)),
            ("mtime", String(identity.mtimeNanoseconds)),
            ("inode", String(identity.inode)),
            ("headTail", identity.headTailSHA256),
            ("ffmpeg", version),
            ("segment", segmentText),
            ("extension", output.pathExtension.lowercased()),
            ("arguments", args.joined(separator: "\u{1}")),
        ])
    }

    private static func segmentText(_ s: PlannedSegment) -> String {
        let outCut: String = s.outCutKeyframe.map { String($0) } ?? "-"
        let zones: [String] = s.damage.map { zone in
            "\(zone.start.bitPattern):\(zone.end.bitPattern):\(zone.affectsVideo)"
        }
        return "\(s.kind)|\(s.range.lowerBound)|\(s.range.upperBound)|\(outCut)|"
            + zones.joined(separator: ",")
    }

    func fetch(_ key: String, to piece: URL) -> Bool {
        let stored = entryURL(key, ext: piece.pathExtension)
        let fm = FileManager.default
        guard fm.fileExists(atPath: stored.path) else {
            lock.withLock { counters.misses += 1 }
            return false
        }
        try? fm.removeItem(at: piece)
        guard Self.cloneOrCopy(stored, to: piece) else {
            lock.withLock { counters.misses += 1 }
            return false
        }
        lock.withLock { counters.hits += 1 }
        return true
    }

    func store(_ key: String, from piece: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = entryURL(key, ext: piece.pathExtension)
        guard !fm.fileExists(atPath: stored.path) else { return }
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).\(piece.pathExtension)")
        guard Self.cloneOrCopy(piece, to: temp) else { return }
        if rename(temp.path, stored.path) != 0 { try? fm.removeItem(at: temp) }
    }

    func evict(_ key: String, ext: String) {
        try? FileManager.default.removeItem(at: entryURL(key, ext: ext))
    }

    private func entryURL(_ key: String, ext: String) -> URL {
        directory.appendingPathComponent("\(key).\(ext)")
    }

    private func identity(of source: URL) -> SourceIdentity? {
        if let known = lock.withLock({ identities[source.path] }) { return known }
        guard let measured = try? SourceIdentity.of(source) else { return nil }
        lock.withLock { identities[source.path] = measured }
        return measured
    }

    private static func cloneOrCopy(_ source: URL, to destination: URL) -> Bool {
        if clonefile(source.path, destination.path, 0) == 0 { return true }
        return (try? FileManager.default.copyItem(at: source, to: destination)) != nil
    }
}
