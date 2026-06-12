import Foundation

/// Establishes a clip's exact frame count by counting video packets (see ADR-0006).
///
/// Slice 1 produces the accurate total frame count, which is what the Source view
/// needs. The deeper per-frame index (frame → PTS + keyframe map) used by the
/// cut-editor and the keyframe-aligned export is built in a later slice, where it
/// is first needed.
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
        // TS files report the video stream twice (once nested under its program,
        // once in the flat stream list), so ffprobe can print the count on more
        // than one line. Take the first integer-parseable line.
        let text = String(data: output.stdout, encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            if let count = Int(line.trimmingCharacters(in: .whitespaces)) {
                return count
            }
        }
        return 0
    }

    /// Builds the full per-frame index in presentation order (ADR-0006): every
    /// frame's PTS and DTS plus a keyframe flag, sorted by PTS (packets arrive in
    /// decode order, which differs from presentation order when B-frames are present).
    /// DTS is carried because the segment-muxer cut is computed from decode time, not
    /// presentation time (ADR-0008).
    ///
    /// The packet dump can be large on long clips, so it streams to a temp file
    /// rather than through a pipe.
    static func buildIndex(url: URL) async throws -> FrameIndex {
        let ffprobe = try FFTools.ffprobeURL()
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidconform-index-\(UUID().uuidString).csv")
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

    /// Builds the index from ffprobe's `packet=pts_time,dts_time,flags` CSV. Pure, so the
    /// timestamp handling is unit-testable.
    ///
    /// Every decoded frame gets exactly one entry — the index frame count must equal the
    /// stream's, because the cut editor numbers frames by this index and the export cuts
    /// by it, so a dropped frame would desync the two and make cuts land wrong (a long
    /// MPEG-2 file had 436 packets with an `N/A` pts that, when dropped, shifted the
    /// numbering and let stream-copied frames leak past the count). A missing pts is
    /// filled from the dts (and vice-versa); only a packet with *neither* timestamp — which
    /// can't be ordered or cut at — is skipped.
    static func parseIndex(csv: String) -> FrameIndex {
        var packets: [PacketStamp] = []
        csv.enumerateLines { line, _ in
            // e.g. "1.480000,1.440000,K__," → fields: [pts, dts, flags, ""]
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard !fields.isEmpty else { return }
            packets.append(PacketStamp(
                pts: Double(fields[0]),
                dts: fields.count > 1 ? Double(fields[1]) : nil,
                keyframe: fields.count > 2 && fields[2].contains("K")))
        }
        return makeIndex(packets)
    }

    /// The shared index-assembly rules (see `parseIndex`): fill a missing pts from the
    /// dts, skip only timestamp-less packets, sort into presentation order.
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

    // MARK: - All-streams scan (issue #45)

    /// One demuxed packet's timestamps as ffprobe reports them — either may be absent
    /// (a damaged source's truncated pictures carry neither).
    struct PacketStamp: Equatable {
        var pts: Double?
        var dts: Double?
        var keyframe: Bool = false
    }

    /// One stream's packets in **demux order** (issue #45) — the damage detector reads
    /// video cadence off the dts sequence as demuxed, not presentation order.
    struct StreamPackets: Equatable {
        var streamIndex: Int
        var isVideo: Bool
        var packets: [PacketStamp]
    }

    /// The import-time read: the frame index plus every stream's packet timestamps.
    struct AllStreamsScan {
        var index: FrameIndex
        var streams: [StreamPackets]
    }

    /// The issue-#45 variant of `buildIndex`: the same single demux pass widened to
    /// **all** audio/video streams, so import gets the frame index and the damage
    /// detector's demux-anomaly input from one read. Audio gaps matter for video
    /// damage too — on the real capture every video damage event has a companion
    /// audio gap, including events that leave no video packet trace.
    static func scanAllStreams(url: URL) async throws -> AllStreamsScan {
        let ffprobe = try FFTools.ffprobeURL()
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidconform-scan-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: dump) }

        let output = try await ProcessRunner.run(ffprobe, [
            "-v", "error",
            "-show_entries", "packet=codec_type,stream_index,pts_time,dts_time,flags",
            "-of", "csv=p=0",
            url.path,
        ], stdoutTo: dump)
        guard output.status == 0 else {
            throw FFError.indexFailed(String(data: output.stderr, encoding: .utf8) ?? "exit \(output.status)")
        }

        let text = try String(contentsOf: dump, encoding: .utf8)
        return parseAllStreams(csv: text)
    }

    /// Builds the scan from ffprobe's `packet=codec_type,stream_index,pts_time,dts_time,
    /// flags` CSV. Pure, so the grouping and the index equivalence are unit-testable.
    /// Only audio and video packets are kept — a broadcast TS also carries teletext/data
    /// streams whose sparse, irregular timing would read as fake gaps. The index is
    /// assembled from the first video stream's packets by the same rules as
    /// `parseIndex`, so the two reads can never disagree about frame numbering.
    static func parseAllStreams(csv: String) -> AllStreamsScan {
        var order: [Int] = []
        var streams: [Int: StreamPackets] = [:]
        csv.enumerateLines { line, _ in
            // e.g. "video,0,1.480000,1.440000,K__," → trailing comma on MPEG-2 streams
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4, fields[0] == "video" || fields[0] == "audio",
                  let streamIndex = Int(fields[1]) else { return }
            let stamp = PacketStamp(
                pts: Double(fields[2]),
                dts: fields.count > 3 ? Double(fields[3]) : nil,
                keyframe: fields.count > 4 && fields[4].contains("K"))
            if streams[streamIndex] == nil {
                streams[streamIndex] = StreamPackets(
                    streamIndex: streamIndex, isVideo: fields[0] == "video", packets: [])
                order.append(streamIndex)
            }
            streams[streamIndex]!.packets.append(stamp)
        }
        let inOrder = order.compactMap { streams[$0] }
        let videoPackets = inOrder.filter(\.isVideo)
            .min { $0.streamIndex < $1.streamIndex }?.packets ?? []
        return AllStreamsScan(index: makeIndex(videoPackets), streams: inOrder)
    }
}
