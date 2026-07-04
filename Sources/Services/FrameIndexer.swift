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
    ///
    /// The scan reads a source sequentially and is linear in file size — minutes on a
    /// multi-GB network file (issue #81), and the dominant cost of damage detection, which
    /// pays it twice (import + verify re-scan). The read itself is irreducible, so the win
    /// is memory: the CSV is **stream-parsed** as it arrives (issue #84) — chunks flow
    /// straight into `LiveScan`'s per-stream `PacketStamp` arrays with the progress fraction
    /// folded into the same pass — so a multi-hour 20–30 GB capture never materializes its
    /// packet dump as one multi-hundred-MB `String`, and there's no temp file to write, read
    /// back, or delete. Only the current chunk plus the irreducible per-stream arrays
    /// detection needs are held at once.
    ///
    /// When `onProgress` and a positive `expectedDuration` are supplied, the caller gets a
    /// bar off the greatest `pts_time` seen vs the duration (the Clip Doctor verify band).
    /// Ordering and completeness of the streamed chunks are load-bearing now — the parse
    /// depends on them — which `ProcessRunner`'s single-reader-plus-EOF-semaphore streaming
    /// path guarantees.
    static func scanAllStreams(
        url: URL,
        expectedDuration: Double? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AllStreamsScan {
        let ffprobe = try FFTools.ffprobeURL()
        // A duration is only wanted when a progress bar is being fed; without one the parse
        // still runs, it just reports no fraction.
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
        // The run has reached EOF (ProcessRunner waits for the reader), so no feed is in
        // flight; assemble the final scan from the accumulated per-stream arrays.
        return live.finish()
    }

    /// Stream-parses the `scanAllStreams` CSV (`codec_type,stream_index,pts_time,dts_time,
    /// flags`) as it arrives (issue #84): assembles lines incrementally via `LineAssembler`,
    /// groups packets into per-stream arrays, and tracks a monotonic pts-progress fraction —
    /// all in **one pass**. So the multi-hundred-MB dump is never held whole as a `String`
    /// (only the current chunk plus the irreducible per-stream `PacketStamp` arrays detection
    /// needs), and the stream isn't parsed twice for progress and packets.
    ///
    /// Progress (issue #81): the greatest `pts_time` seen so far, minus the first stamp (a TS
    /// stream's pts starts at an arbitrary clock offset), over the total duration. The scan
    /// reads packets in demux order so pts climbs roughly with bytes read — the natural signal
    /// for a sequential network read — and taking the running *max* keeps it strictly
    /// non-decreasing through the odd out-of-order or missing stamp. Pure, so it's unit-testable.
    struct StreamingAllStreamsScan {
        private var lines = LineAssembler()
        private var order: [Int] = []
        private var streams: [Int: StreamPackets] = [:]
        private var maxPts = 0.0
        private var firstPts: Double? = nil
        let duration: Double

        /// `duration` drives the progress fraction; pass 0 (the default) when only the parsed
        /// scan is wanted and no bar is fed — parsing runs regardless.
        init(duration: Double = 0) { self.duration = duration }

        /// Feeds one CSV chunk: parses every completed line into the per-stream arrays, and
        /// returns the progress fraction 0…1 if a later `pts_time` advanced it (nil when no
        /// completed line carried a later stamp — so the bar isn't re-poked — or when there's
        /// no positive duration).
        mutating func feed(_ chunk: String) -> Double? {
            var advanced = false
            for line in lines.feed(chunk) { if ingest(line) { advanced = true } }
            return fraction(advanced: advanced)
        }

        /// Flushes any final unterminated line and assembles the scan. The index is built from
        /// the lowest-numbered video stream's packets by the same `makeIndex` rules as
        /// `parseIndex`, so this scan's frame index can never disagree with the single-stream
        /// index about frame numbering.
        mutating func finish() -> AllStreamsScan {
            if let last = lines.finish() { _ = ingest(last) }
            let inOrder = order.compactMap { streams[$0] }
            let videoPackets = inOrder.filter(\.isVideo)
                .min { $0.streamIndex < $1.streamIndex }?.packets ?? []
            return AllStreamsScan(index: makeIndex(videoPackets), streams: inOrder)
        }

        /// Parses one CSV line into a packet appended to its stream, and folds its `pts_time`
        /// into the running progress max; returns whether it advanced that max. Only audio and
        /// video packets are kept — a broadcast TS also carries teletext/data streams whose
        /// sparse, irregular timing would read as fake gaps (and would jitter progress).
        private mutating func ingest(_ line: String) -> Bool {
            // e.g. "video,0,1.480000,1.440000,K__," → trailing comma on MPEG-2 streams
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
            if firstPts == nil {           // first real stamp seeds the baseline
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

    /// Builds the scan from a whole `scanAllStreams` CSV in one shot — the pure entry point
    /// the unit tests drive. Feeds the string through the same incremental
    /// `StreamingAllStreamsScan` the live scan uses, so the two can't diverge; the live path
    /// just feeds it chunk-by-chunk instead.
    static func parseAllStreams(csv: String) -> AllStreamsScan {
        var scan = StreamingAllStreamsScan()
        _ = scan.feed(csv)
        return scan.finish()
    }
}

/// Thread-safe wrapper around `FrameIndexer.StreamingAllStreamsScan` for the streamed scan
/// (issues #81, #84) — one per scan, fed from `ProcessRunner`'s serial reader queue, so the
/// lock guards the incremental parse. `feed` reports live progress as chunks arrive; `finish`
/// (called once the run has reached EOF, so no `feed` is in flight) returns the assembled scan.
/// The CSV packet arrays are built here as the file streams in, never materialized as a whole
/// `String` — the memory win of issue #84.
final class LiveScan: @unchecked Sendable {
    private var scan: FrameIndexer.StreamingAllStreamsScan
    private let lock = NSLock()

    init(duration: Double) { scan = FrameIndexer.StreamingAllStreamsScan(duration: duration) }

    /// Feeds one stdout chunk into the parse; returns the latest progress fraction it advanced
    /// to, if any. The CSV fields are pure ASCII, so a chunk never splits a UTF-8 codepoint.
    func feed(_ data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return scan.feed(text)
    }

    /// Assembles the final scan after the stream reaches EOF.
    func finish() -> FrameIndexer.AllStreamsScan {
        lock.lock()
        defer { lock.unlock() }
        return scan.finish()
    }
}
