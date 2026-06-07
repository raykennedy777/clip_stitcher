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
    /// frame's PTS plus a keyframe flag, sorted by PTS (packets arrive in decode
    /// order, which differs from presentation order when B-frames are present).
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
            "-show_entries", "packet=pts_time,flags",
            "-of", "csv=p=0",
            url.path,
        ], stdoutTo: dump)
        guard output.status == 0 else {
            throw FFError.indexFailed(String(data: output.stderr, encoding: .utf8) ?? "exit \(output.status)")
        }

        let text = try String(contentsOf: dump, encoding: .utf8)
        var entries: [(pts: Double, keyframe: Bool)] = []
        text.enumerateLines { line, _ in
            // e.g. "1.480000,K__," → fields: [pts, flags, ""]
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = fields.first, let pts = Double(first) else { return }
            let keyframe = fields.count > 1 && fields[1].contains("K")
            entries.append((pts, keyframe))
        }
        entries.sort { $0.pts < $1.pts }
        return FrameIndex(pts: entries.map(\.pts), keyframeFlags: entries.map(\.keyframe))
    }
}
