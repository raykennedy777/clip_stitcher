import Foundation

/// The **piece cache** (R1 of the 2026 R16 clipstitch review): the re-encoded pieces of an
/// earlier render, kept on disk and reused when a later render would run the same encode.
/// A render of the R16 MotoGP job spends 80–85 % of its time in x265, and a job edit that
/// moves one Fill changes only the pieces that Fill and its neighbours' edges touch.
///
/// Scope: boundary re-encodes, repaired segments and conforms — every piece an encoder
/// makes. Copy pieces are not cached; they cost a stream copy.
///
/// The key is the source's `SourceIdentity`, the ffmpeg build, the planned segment, and the
/// **exact** ffmpeg argument array with the output piece's path replaced by a placeholder.
/// The arguments carry every encoder setting (codec, CRF, reorder-depth params, timescale
/// pin, bitstream filters, seek, frame selection), so any change to any of them is a miss.
/// A hit copies the stored bytes into the work directory under the name the encode would
/// have written, and the piece's verify gate runs as on a fresh encode — a hit skips the
/// encoder, never the gate. A piece is stored only after its gate passes.
///
/// Opt-in (`clipstitch --piece-cache <dir>`): without the flag nothing is read or written,
/// and the export runs the same commands as before. The directory is never pruned; delete
/// it to reclaim the space.
final class PieceCache: @unchecked Sendable {
    /// Bump when the key's parts or the stored form change meaning.
    static let schema = 1

    let directory: URL
    private let lock = NSLock()
    private var identities: [String: SourceIdentity] = [:]
    private var counters = (hits: 0, misses: 0)

    init(directory: URL) {
        self.directory = directory
    }

    /// The hits and misses so far in this process, for the run's summary line.
    var hits: Int { lock.withLock { counters.hits } }
    var misses: Int { lock.withLock { counters.misses } }

    /// The placeholder that stands for the output piece in a key's arguments.
    static let outputPlaceholder = "<piece>"

    /// The key of one encode, or nil when the source cannot be identified (the encode then
    /// runs uncached).
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

    /// The planned segment as key text: kind, range, out-cut keyframe and damage zones.
    private static func segmentText(_ s: PlannedSegment) -> String {
        let outCut: String = s.outCutKeyframe.map { String($0) } ?? "-"
        let zones: [String] = s.damage.map { zone in
            "\(zone.start.bitPattern):\(zone.end.bitPattern):\(zone.affectsVideo)"
        }
        return "\(s.kind)|\(s.range.lowerBound)|\(s.range.upperBound)|\(outCut)|"
            + zones.joined(separator: ",")
    }

    /// Copies the stored piece for `key` to `piece`. True on a hit.
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

    /// Stores `piece` under `key`. Copied to a temporary name and renamed, so a concurrent
    /// render never reads half a piece. Best effort: a failed store costs the next render
    /// an encode, nothing else.
    func store(_ key: String, from piece: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = entryURL(key, ext: piece.pathExtension)
        guard !fm.fileExists(atPath: stored.path) else { return }
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).\(piece.pathExtension)")
        guard Self.cloneOrCopy(piece, to: temp) else { return }
        if rename(temp.path, stored.path) != 0 { try? fm.removeItem(at: temp) }
    }

    /// Removes the stored piece for `key`. Called when a piece taken from the cache fails
    /// its verify gate, so the next render encodes it again instead of failing the same way.
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

    /// An APFS clone when both paths are on one volume (no data copied), else a copy.
    private static func cloneOrCopy(_ source: URL, to destination: URL) -> Bool {
        if clonefile(source.path, destination.path, 0) == 0 { return true }
        return (try? FileManager.default.copyItem(at: source, to: destination)) != nil
    }
}
