import Foundation

enum FrameIndexer {
    static func frameCount(url: URL) async throws -> Int {
        let ffprobe = try FFTools.ffprobeURL()
        let output = try await ProcessRunner.run(ffprobe, [
            "-v", "error",
            "-select_streams", "v:0",
            "-count_packets",
            "-show_entries", "stream=nb_read_packets",
            "-of", "default=nokey=1:noprint_wrappers=1",
            url.path,
        ])
        guard output.status == 0 else {
            throw FFError.indexFailed(String(data: output.stderr, encoding: .utf8) ?? "exit \(output.status)")
        }
        let text = String(data: output.stdout, encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            if let count = Int(line.trimmingCharacters(in: .whitespaces)) {
                return count
            }
        }
        return 0
    }

    static func buildIndex(url: URL) async throws -> FrameIndex {
        let ffprobe = try FFTools.ffprobeURL()
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-index-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: dump) }

        let output = try await ProcessRunner.run(ffprobe, [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "packet=pts_time,dts_time,flags",
            "-of", "csv=p=0",
            url.path,
        ], stdoutTo: dump)
        guard output.status == 0 else {
            throw FFError.indexFailed(String(data: output.stderr, encoding: .utf8) ?? "exit \(output.status)")
        }

        let text = try String(contentsOf: dump, encoding: .utf8)
        return parseIndex(csv: text)
    }

    static func parseIndex(csv: String) -> FrameIndex {
        var packets: [PacketStamp] = []
        csv.enumerateLines { line, _ in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard !fields.isEmpty else { return }
            packets.append(PacketStamp(
                pts: Double(fields[0]),
                dts: fields.count > 1 ? Double(fields[1]) : nil,
                keyframe: fields.count > 2 && fields[2].contains("K")))
        }
        return makeIndex(packets)
    }

    // ADR-0006
    static func makeIndex(_ packets: [PacketStamp]) -> FrameIndex {
        var entries: [(pts: Double, dts: Double, keyframe: Bool)] = []
        for p in packets {
            guard let pts = p.pts ?? p.dts else { continue }
            entries.append((pts, p.dts ?? pts, p.keyframe))
        }
        entries.sort { $0.pts < $1.pts }
        return FrameIndex(
            pts: entries.map(\.pts),
            dts: entries.map(\.dts),
            keyframeFlags: entries.map(\.keyframe)
        )
    }

    struct PacketStamp: Equatable {
        var pts: Double?
        var dts: Double?
        var keyframe: Bool = false
    }

    struct StreamPackets: Equatable {
        var streamIndex: Int
        var isVideo: Bool
        var packets: [PacketStamp]
    }

    struct AllStreamsScan {
        var index: FrameIndex
        var streams: [StreamPackets]
    }

    // ADR-0006, ADR-0020
    static func scanAllStreams(
        url: URL,
        expectedDuration: Double? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AllStreamsScan {
        let ffprobe = try FFTools.ffprobeURL()
        let live = LiveScan(duration: onProgress == nil ? 0 : (expectedDuration ?? 0))

        let output = try await ProcessRunner.run(ffprobe, [
            "-v", "error",
            "-show_entries", "packet=codec_type,stream_index,pts_time,dts_time,flags",
            "-of", "csv=p=0",
            url.path,
        ], onStdout: { chunk in
            if let f = live.feed(chunk) { onProgress?(f) }
        })
        guard output.status == 0 else {
            throw FFError.indexFailed(String(data: output.stderr, encoding: .utf8) ?? "exit \(output.status)")
        }
        return live.finish()
    }

    struct StreamingAllStreamsScan {
        private var lines = LineAssembler()
        private var order: [Int] = []
        private var streams: [Int: StreamPackets] = [:]
        private var maxPts = 0.0
        private var firstPts: Double? = nil
        let duration: Double

        init(duration: Double = 0) { self.duration = duration }

        mutating func feed(_ chunk: String) -> Double? {
            var advanced = false
            for line in lines.feed(chunk) { if ingest(line) { advanced = true } }
            return fraction(advanced: advanced)
        }

        mutating func finish() -> AllStreamsScan {
            if let last = lines.finish() { _ = ingest(last) }
            let inOrder = order.compactMap { streams[$0] }
            let videoPackets = inOrder.filter(\.isVideo)
                .min { $0.streamIndex < $1.streamIndex }?.packets ?? []
            return AllStreamsScan(index: makeIndex(videoPackets), streams: inOrder)
        }

        private mutating func ingest(_ line: String) -> Bool {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4, fields[0] == "video" || fields[0] == "audio",
                  let streamIndex = Int(fields[1]) else { return false }
            let pts = Double(fields[2])
            let stamp = PacketStamp(
                pts: pts,
                dts: fields.count > 3 ? Double(fields[3]) : nil,
                keyframe: fields.count > 4 && fields[4].contains("K"))
            if streams[streamIndex] == nil {
                streams[streamIndex] = StreamPackets(
                    streamIndex: streamIndex, isVideo: fields[0] == "video", packets: [])
                order.append(streamIndex)
            }
            streams[streamIndex]!.packets.append(stamp)
            guard let pts else { return false }
            if firstPts == nil {
                firstPts = pts
                maxPts = pts
                return true
            }
            if pts > maxPts { maxPts = pts; return true }
            return false
        }

        private func fraction(advanced: Bool) -> Double? {
            guard duration > 0, advanced else { return nil }
            return min(max((maxPts - (firstPts ?? 0)) / duration, 0), 1)
        }
    }

    static func parseAllStreams(csv: String) -> AllStreamsScan {
        var scan = StreamingAllStreamsScan()
        _ = scan.feed(csv)
        return scan.finish()
    }
}

final class LiveScan: @unchecked Sendable {
    private var scan: FrameIndexer.StreamingAllStreamsScan
    private let lock = NSLock()

    init(duration: Double) { scan = FrameIndexer.StreamingAllStreamsScan(duration: duration) }

    func feed(_ data: Data) -> Double? {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        lock.lock()
        defer { lock.unlock() }
        return scan.feed(text)
    }

    func finish() -> FrameIndexer.AllStreamsScan {
        lock.lock()
        defer { lock.unlock() }
        return scan.finish()
    }
}
