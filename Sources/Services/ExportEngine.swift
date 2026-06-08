import Foundation

/// One clip's contribution to an export: where it lives and the keyframe-aligned plan
/// of what to keep (ADR-0008). `codec` is the ffprobe `codec_name`, used to refuse a
/// stream-copy concat across different codecs (that is conform — Milestone 3 — not M1).
struct ExportItem {
    var source: URL
    var plan: SegmentPlan
    var codec: String?
}

enum ExportError: LocalizedError {
    case noClips
    case invalidPlan
    case mixedCodecs
    case cutFailed(String)
    case concatFailed(String)
    case missingSegment

    var errorDescription: String? {
        switch self {
        case .noClips: return "There are no clips to export."
        case .invalidPlan: return "A clip's in/out points collapse to nothing after snapping to clean cut points."
        case .mixedCodecs: return "Connecting clips of different codecs into one file needs re-encoding (a later milestone). Export them separately, or use clips that share a codec."
        case .cutFailed(let d): return "Could not cut a clip.\n\(d)"
        case .concatFailed(let d): return "Could not join the clips.\n\(d)"
        case .missingSegment: return "The expected output segment was not produced."
        }
    }
}

/// Milestone 1 export: cut each clip at its clean cut points with a pure stream-copy
/// (the ffmpeg segment muxer), then either concat the pieces into one file or write
/// them out separately (ADR-0008). No re-encode — frame-exact or it does not cut there.
///
/// The argument builders are pure so the exact command shape can be unit-tested; the
/// recipes themselves were validated against real H.264/HEVC/MPEG-2 footage in the shell.
enum ExportEngine {
    /// Whether the plan trims either end. When neither end is cut the clip is copied
    /// whole with a plain remux — the segment muxer would otherwise split it at *every*
    /// keyframe (it only honours explicit cut points).
    static func needsCut(_ plan: SegmentPlan) -> Bool {
        plan.inSegmentTime != nil || plan.outSegmentTime != nil
    }

    /// The segment the wanted piece lands in: index 0 when the clip starts at its own
    /// beginning (no head cut), otherwise index 1 — the piece after the in-cut.
    static func wantedSegmentIndex(plan: SegmentPlan) -> Int {
        plan.inSegmentTime == nil ? 0 : 1
    }

    /// ffmpeg args to cut one clip into segments at its clean cut points, copying the
    /// streams selected by `type`. Cuts are placed by **decode** time (ADR-0008): the
    /// muxer splits at the first keyframe whose DTS reaches the segment time. With
    /// explicit `-segment_times` the muxer splits *only* there, so internal keyframes
    /// are carried through untouched. Assumes `needsCut(plan)`.
    static func cutArguments(source: URL, plan: SegmentPlan, type: OutputType, segmentPattern: String) -> [String] {
        var args = ["-v", "error", "-i", source.path]
        args += streamMaps(type)
        args += ["-c", "copy", "-f", "segment"]
        let times = [plan.inSegmentTime, plan.outSegmentTime].compactMap { $0 }
        args += ["-segment_times", times.map(Self.timeString).joined(separator: ",")]
        args += ["-reset_timestamps", "1", segmentPattern]
        return args
    }

    /// ffmpeg args to copy a whole clip to a single file (no cut), selecting streams by
    /// `type`. Used when the plan trims neither end.
    static func remuxArguments(source: URL, type: OutputType, output: URL) -> [String] {
        var args = ["-v", "error", "-i", source.path]
        args += streamMaps(type)
        args += ["-c", "copy", output.path]
        return args
    }

    /// ffmpeg args to join already-cut, same-codec pieces with the concat demuxer — a
    /// pure stream-copy, so the join is frame-exact.
    static func concatArguments(listFile: URL, output: URL) -> [String] {
        ["-v", "error", "-f", "concat", "-safe", "0", "-i", listFile.path, "-c", "copy", output.path]
    }

    /// The concat demuxer's list file: one `file '<path>'` line per piece. Single quotes
    /// in a path are escaped (`'\''`) so a filename can't break out of the directive.
    static func concatListContents(pieces: [URL]) -> String {
        pieces.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n") + "\n"
    }

    private static func streamMaps(_ type: OutputType) -> [String] {
        switch type {
        case .videoAndAudio: return ["-map", "0:v:0", "-map", "0:a:0?"]
        case .videoOnly:     return ["-map", "0:v:0"]
        case .audioOnly:     return ["-map", "0:a:0"]
        }
    }

    /// ffmpeg prints times locale-independently; format without scientific notation or
    /// a trailing locale decimal separator.
    private static func timeString(_ t: Double) -> String {
        var s = String(format: "%.6f", t)
        // trim trailing zeros / dot so 0.30 -> "0.3", matching the de-risk recipe.
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    // MARK: - Orchestration

    /// Runs the full export: cut every clip, then connect or separate per `settings`.
    /// `destination` is the file the user chose; in `.separate` mode each clip is written
    /// alongside it as `name-1.ext`, `name-2.ext`, … `progress` reports 0…1.
    static func export(
        items: [ExportItem],
        settings: OutputSettings,
        to destination: URL,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        guard !items.isEmpty else { throw ExportError.noClips }
        guard items.allSatisfy(\.plan.isValid) else { throw ExportError.invalidPlan }
        if settings.mode == .connect {
            let codecs = Set(items.map { $0.codec ?? "?" })
            guard codecs.count == 1 else { throw ExportError.mixedCodecs }
        }

        let ffmpeg = try FFTools.ffmpegURL()
        let ext = settings.container.fileExtension
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidconform-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Cut each clip to its single wanted piece. This is the bulk of the work, so it
        // drives most of the progress bar (a concat at the end is comparatively cheap).
        let cutShare = settings.mode == .connect ? 0.9 : 1.0
        var pieces: [URL] = []
        for (i, item) in items.enumerated() {
            let piece: URL
            if needsCut(item.plan) {
                let pattern = work.appendingPathComponent("clip\(i)_%03d.\(ext)").path
                try await runFFmpeg(ffmpeg, cutArguments(source: item.source, plan: item.plan,
                                                          type: settings.type, segmentPattern: pattern),
                                    failure: ExportError.cutFailed)
                piece = work.appendingPathComponent(
                    String(format: "clip\(i)_%03d.\(ext)", wantedSegmentIndex(plan: item.plan))
                )
            } else {
                piece = work.appendingPathComponent("clip\(i).\(ext)")
                try await runFFmpeg(ffmpeg, remuxArguments(source: item.source, type: settings.type, output: piece),
                                    failure: ExportError.cutFailed)
            }
            guard FileManager.default.fileExists(atPath: piece.path) else { throw ExportError.missingSegment }
            pieces.append(piece)
            progress(cutShare * Double(i + 1) / Double(items.count))
        }

        switch settings.mode {
        case .connect:
            let listFile = work.appendingPathComponent("concat.txt")
            try concatListContents(pieces: pieces).write(to: listFile, atomically: true, encoding: .utf8)
            try await runFFmpeg(ffmpeg, concatArguments(listFile: listFile, output: destination),
                                failure: ExportError.concatFailed)
        case .separate:
            try writeSeparately(pieces: pieces, to: destination, ext: ext)
        }
        progress(1.0)
    }

    /// Runs ffmpeg and turns a non-zero exit into `failure(stderr)`.
    private static func runFFmpeg(_ ffmpeg: URL, _ args: [String], failure: (String) -> ExportError) async throws {
        let result = try await ProcessRunner.run(ffmpeg, args)
        guard result.status == 0 else {
            throw failure(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
    }

    /// Moves each cut piece next to the chosen file as `name-1.ext`, `name-2.ext`, …
    /// (a single clip keeps the chosen name).
    private static func writeSeparately(pieces: [URL], to destination: URL, ext: String) throws {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent
        for (i, piece) in pieces.enumerated() {
            let name = pieces.count == 1 ? "\(stem).\(ext)" : "\(stem)-\(i + 1).\(ext)"
            let out = dir.appendingPathComponent(name)
            try? fm.removeItem(at: out)
            try fm.moveItem(at: piece, to: out)
        }
    }
}
