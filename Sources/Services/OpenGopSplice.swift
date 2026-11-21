import Foundation

// ADR-0038
enum OpenGopSplice {
    static let blaWithLeading = 16
    static let blaWithRadl = 17
    static let blaNoLeading = 18
    static let cra = 21

    // ADR-0038
    static func leadingPictureDropFilter(keyframe: Int, count: Int, index: FrameIndex,
                                         containerStart: Double, seek: Double) -> String {
        let interval = index.pts.count > 1
            ? (index.pts[index.pts.count - 1] - index.pts[0]) / Double(index.pts.count - 1)
            : 0.04
        let guardBand = interval / 4
        let dtsLimit = index.dts[keyframe] - containerStart - seek - guardBand
        let ptsLimit = index.pts[keyframe] - containerStart - seek - guardBand
        let drop = "noise=drop='gte(dts*tb\\,\(ExportEngine.timeString(dtsLimit)))"
            + "*lt(pts*tb\\,\(ExportEngine.timeString(ptsLimit)))'"
        let leading = (keyframe - count)..<keyframe
        guard count > 0, leading.lowerBound >= 0,
              let slot = leading.map({ index.dts[$0] }).max(), slot > index.dts[keyframe]
        else { return drop }
        let keyframePts = index.pts[keyframe] - containerStart - seek
        let moved = slot - containerStart - seek
        return drop + ",setts=pts=PTS:dts='if(lt(abs(PTS*TB-(\(ExportEngine.timeString(keyframePts))))"
            + "\\,\(ExportEngine.timeString(guardBand)))\\,\(ExportEngine.timeString(moved))/TB\\,DTS)'"
    }

    // ADR-0038
    static func prependingDrop(_ drop: String, to chain: [String]) -> [String] {
        guard chain.count == 2, chain[0] == "-bsf:v" else { return ["-bsf:v", drop] }
        return ["-bsf:v", "\(drop),\(chain[1])"]
    }

    enum Framing: Equatable {
        case lengthPrefixed
        case annexB
    }

    static func irapHeaderOffsets(in bytes: [UInt8], framing: Framing) -> [Int]? {
        let headers: [Int]
        switch framing {
        case .lengthPrefixed: guard let h = lengthPrefixedHeaders(bytes) else { return nil }; headers = h
        case .annexB: headers = annexBHeaders(bytes)
        }
        var offsets: [Int] = []
        for h in headers {
            let type = Int(bytes[h] >> 1) & 0x3F
            guard type < 32 else {
                if offsets.isEmpty { continue } else { break }
            }
            guard type == cra || type == blaWithLeading || type == blaWithRadl else {
                if offsets.isEmpty { return nil } else { break }
            }
            offsets.append(h)
        }
        return offsets.isEmpty ? nil : offsets
    }

    static func blaHeaderByte(_ byte: UInt8) -> UInt8 {
        (byte & 0x81) | UInt8(blaNoLeading << 1)
    }

    private static func lengthPrefixedHeaders(_ bytes: [UInt8]) -> [Int]? {
        var headers: [Int] = []
        var i = 0
        while i < bytes.count {
            guard i + 6 <= bytes.count else { return nil }
            let length = bytes[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 2, i + 4 + length <= bytes.count else { return nil }
            headers.append(i + 4)
            i += 4 + length
        }
        return headers
    }

    private static func annexBHeaders(_ bytes: [UInt8]) -> [Int] {
        var headers: [Int] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                headers.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        return headers
    }

    static func tsPesPayload(_ bytes: [UInt8]) -> (payload: [UInt8], positions: [Int])? {
        let size = 188
        guard bytes.count >= size, bytes[0] == 0x47, bytes[1] & 0x40 != 0 else { return nil }
        let pid = (Int(bytes[1]) & 0x1F) << 8 | Int(bytes[2])
        var payload: [UInt8] = [], positions: [Int] = []
        var p = 0
        while p + size <= bytes.count, bytes[p] == 0x47 {
            let thisPid = (Int(bytes[p + 1]) & 0x1F) << 8 | Int(bytes[p + 2])
            let unitStart = bytes[p + 1] & 0x40 != 0
            if thisPid == pid {
                if unitStart, p > 0 { break }
                let control = (bytes[p + 3] >> 4) & 0x3
                var start = p + 4
                if control & 0x2 != 0 { start += 1 + Int(bytes[p + 4]) }
                if control & 0x1 != 0, start < p + size {
                    for q in start..<(p + size) { payload.append(bytes[q]); positions.append(q) }
                }
            }
            p += size
        }
        guard payload.count > 9, payload[0] == 0, payload[1] == 0, payload[2] == 1 else { return nil }
        let skip = 9 + Int(payload[8])
        guard skip < payload.count else { return nil }
        return (Array(payload[skip...]), Array(positions[skip...]))
    }

    // ADR-0038
    static func rewriteFirstIrapToBLA(_ ffprobe: URL, piece: URL) async throws {
        func refuse(_ why: String) -> ExportError {
            .verificationFailed("The in-point splice could not rewrite \(piece.lastPathComponent): \(why).")
        }
        let probe = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1",
            "-show_entries", "packet=pos,size", "-of", "default=noprint_wrappers=1", piece.path])
        let fields = Dictionary(
            (String(data: probe.stdout, encoding: .utf8) ?? "")
                .split(separator: "\n").compactMap { line -> (String, Int)? in
                    let kv = line.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2, let v = Int(kv[1]) else { return nil }
                    return (String(kv[0]), v)
                }, uniquingKeysWith: { first, _ in first })
        guard probe.status == 0, let pos = fields["pos"], let size = fields["size"], pos >= 0, size > 0
        else { throw refuse("ffprobe gave no first-packet position") }

        let handle = try FileHandle(forUpdating: piece)
        defer { try? handle.close() }
        let ext = piece.pathExtension.lowercased()
        let readLength = ext == "ts" ? (size / 184 + 4) * 188 : size + 16
        try handle.seek(toOffset: UInt64(pos))
        let window = [UInt8](try handle.read(upToCount: readLength) ?? Data())

        var patches: [(offset: Int, byte: UInt8)] = []
        switch ext {
        case "mp4", "mov", "m4v":
            guard window.count >= size else { throw refuse("the packet is truncated") }
            let data = Array(window[0..<size])
            guard let offsets = irapHeaderOffsets(in: data, framing: .lengthPrefixed)
            else { throw refuse("the first picture is not an open IRAP") }
            patches = offsets.map { (pos + $0, blaHeaderByte(data[$0])) }
        case "mkv":
            guard let first = window.first, first != 0 else { throw refuse("no block header") }
            let vintLength = first.leadingZeroBitCount + 1
            let start = vintLength + 3
            guard window.count >= start + size else { throw refuse("the packet is truncated") }
            let data = Array(window[start..<start + size])
            guard let offsets = irapHeaderOffsets(in: data, framing: .lengthPrefixed)
            else { throw refuse("the first picture is not an open IRAP") }
            patches = offsets.map { (pos + start + $0, blaHeaderByte(data[$0])) }
        case "ts":
            guard let pes = tsPesPayload(window),
                  let offsets = irapHeaderOffsets(in: pes.payload, framing: .annexB)
            else { throw refuse("the first picture is not an open IRAP") }
            patches = offsets.map { (pos + pes.positions[$0], blaHeaderByte(pes.payload[$0])) }
        default:
            throw refuse("no rewrite for .\(ext) pieces")
        }
        for patch in patches {
            try handle.seek(toOffset: UInt64(patch.offset))
            try handle.write(contentsOf: Data([patch.byte]))
        }
    }
}
