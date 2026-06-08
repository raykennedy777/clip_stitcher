import Foundation

/// One clip's contribution to an export: where it lives and the Milestone 2 plan of what
/// to keep (ADR-0009) — an ordered list of copy / re-encode `segments` over `index`,
/// produced with `encoder` (the source-matched re-encode args). `codec` is the ffprobe
/// `codec_name`, used to refuse a stream-copy concat across different codecs (that is
/// conform — a later milestone).
///
/// `audioStart`/`audioEnd` are the clip's kept range in **source presentation time**
/// (seconds) — the audio is re-encoded over exactly this window so it stays aligned with
/// the video and the joins are gap-free (ADR-0008). `nil` means that end is the clip
/// boundary (no cut there).
struct ExportItem {
    var source: URL
    var codec: String? = nil
    var segments: [PlannedSegment] = []
    var index: FrameIndex = FrameIndex(pts: [], keyframeFlags: [])
    var encoder: [String] = []
    var audioStart: Double? = nil
    var audioEnd: Double? = nil
}

enum ExportError: LocalizedError {
    case noClips
    case invalidPlan
    case mixedCodecs
    case unsupportedContainer(codec: String, container: String)
    case cutFailed(String)
    case concatFailed(String)
    case missingSegment
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noClips: return "There are no clips to export."
        case .invalidPlan: return "A clip's in/out points collapse to nothing after snapping to clean cut points."
        case .mixedCodecs: return "Connecting clips of different codecs into one file needs re-encoding (a later milestone). Export them separately, or use clips that share a codec."
        case .unsupportedContainer(let codec, let container):
            return "The \(container.uppercased()) container can't carry \(codec) video by stream-copy. Choose TS (recommended for this footage) or MP4."
        case .cutFailed(let d): return "Could not cut a clip.\n\(d)"
        case .concatFailed(let d): return "Could not join the clips.\n\(d)"
        case .missingSegment: return "The expected output segment was not produced."
        case .verificationFailed(let d): return "The cut did not verify and was not saved.\n\(d)"
        }
    }
}

/// Milestone 1 export: cut each clip at its clean cut points with a pure video
/// stream-copy (the ffmpeg segment muxer), then connect or separate the pieces
/// (ADR-0008). No video re-encode — frame-exact or it does not cut there.
///
/// Audio is **re-encoded** rather than copied: a stream-copied audio cut lands on an
/// audio-packet boundary, not the video cut, leaving the two ~tens of ms apart at every
/// join (measured ~120 ms on real footage). Instead each clip's audio is decoded over
/// its exact kept range and concatenated at the sample level into one continuous track
/// (a single encode — no per-join priming gaps), then muxed against the copied video.
///
/// The argument builders are pure so the exact command shape can be unit-tested; the
/// recipes themselves were validated against real H.264/HEVC/MPEG-2 footage in the shell.
enum ExportEngine {
    /// Re-encode target for the rebuilt audio track. AAC is broadly supported across the
    /// TS/MKV/MP4 containers and audibly transparent at this bitrate.
    private static let audioCodec = "aac"
    private static let audioBitrate = "192k"

    /// Whether a codec can be stream-copied into a container. Matroska rejects MPEG-2's
    /// unknown/non-monotonic timestamps at the cut joins (verified in the shell — it fails
    /// with "Can't write packet with unknown timestamp"); TS and MP4 tolerate them, and
    /// H.264/HEVC are fine in all three.
    static func streamCopyCompatible(codec: String?, container: Container) -> Bool {
        !(container == .mkv && codec == "mpeg2video")
    }

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

    /// ffmpeg args to cut one clip's **video** into segments at its clean cut points.
    /// Cuts are placed by **decode** time (ADR-0008): the muxer splits at the first
    /// keyframe whose DTS reaches the segment time. With explicit `-segment_times` the
    /// muxer splits *only* there, so internal keyframes are carried through untouched.
    /// Assumes `needsCut(plan)`.
    static func cutArguments(source: URL, plan: SegmentPlan, segmentPattern: String) -> [String] {
        var args = ["-v", "error", "-i", source.path, "-map", "0:v:0", "-c", "copy", "-f", "segment"]
        let times = [plan.inSegmentTime, plan.outSegmentTime].compactMap { $0 }
        args += ["-segment_times", times.map(Self.timeString).joined(separator: ",")]
        args += ["-reset_timestamps", "1", segmentPattern]
        return args
    }

    /// ffmpeg args to copy a whole clip's **video** to a single file (no cut). Used when
    /// the plan trims neither end.
    static func remuxArguments(source: URL, output: URL) -> [String] {
        ["-v", "error", "-i", source.path, "-map", "0:v:0", "-c", "copy", output.path]
    }

    /// ffmpeg args to join already-cut, same-codec video pieces with the concat demuxer —
    /// a pure stream-copy, so the join is frame-exact.
    static func concatArguments(listFile: URL, output: URL) -> [String] {
        ["-v", "error", "-f", "concat", "-safe", "0", "-i", listFile.path, "-c", "copy", output.path]
    }

    /// The concat demuxer's list file: one `file '<path>'` line per piece. Single quotes
    /// in a path are escaped (`'\''`) so a filename can't break out of the directive.
    static func concatListContents(pieces: [URL]) -> String {
        pieces.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n") + "\n"
    }

    /// Input args selecting one clip's audio source range: a fast seek to `start` and a
    /// read duration. `-ss`/`-t` before `-i` are input options. An open start/end omits
    /// the corresponding flag (read from the file start / to the file end).
    static func audioInputArgs(source: URL, start: Double?, end: Double?) -> [String] {
        var a: [String] = []
        if let start { a += ["-ss", timeString(start)] }
        if let end { a += ["-t", timeString(end - (start ?? 0))] }
        a += ["-i", source.path]
        return a
    }

    /// Final-mux args: copy `videoInput`'s video (when present) and build one continuous,
    /// re-encoded audio track by concatenating each item's source audio range at the
    /// sample level. `videoInput` is `nil` for an audio-only export.
    static func audioMuxArguments(videoInput: URL?, items: [ExportItem], output: URL) -> [String] {
        var args = ["-v", "error"]
        var audioBase = 0
        if let videoInput {
            args += ["-i", videoInput.path]
            audioBase = 1
        }
        for item in items {
            args += audioInputArgs(source: item.source, start: item.audioStart, end: item.audioEnd)
        }
        let labels = (0..<items.count).map { "[\(audioBase + $0):a:0]" }.joined()
        args += ["-filter_complex", "\(labels)concat=n=\(items.count):v=0:a=1[a]"]
        if videoInput != nil { args += ["-map", "0:v:0", "-c:v", "copy"] }
        args += ["-map", "[a]", "-c:a", audioCodec, "-b:a", audioBitrate, output.path]
        return args
    }

    /// ffmpeg prints times locale-independently; format without scientific notation or
    /// a trailing locale decimal separator. Shared with the M2 boundary-re-encode engine.
    static func timeString(_ t: Double) -> String {
        var s = String(format: "%.6f", t)
        // trim trailing zeros / dot so 0.30 -> "0.3", matching the de-risk recipe.
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    // MARK: - Orchestration

    /// Runs the full export: cut every clip's video, then connect or separate per
    /// `settings`, rebuilding the audio track when the output includes audio. `destination`
    /// is the file the user chose; in `.separate` mode each clip is written alongside it as
    /// `name-1.ext`, `name-2.ext`, … `progress` reports 0…1.
    static func export(
        items: [ExportItem],
        settings: OutputSettings,
        to destination: URL,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        guard !items.isEmpty else { throw ExportError.noClips }
        let wantsVideo = settings.type != .audioOnly
        if wantsVideo {
            guard items.allSatisfy({ !$0.segments.isEmpty }) else { throw ExportError.invalidPlan }
        }
        if settings.mode == .connect {
            guard Set(items.map { $0.codec ?? "?" }).count == 1 else { throw ExportError.mixedCodecs }
        }
        for item in items where !streamCopyCompatible(codec: item.codec, container: settings.container) {
            throw ExportError.unsupportedContainer(codec: item.codec ?? "this", container: settings.container.fileExtension)
        }

        let ffmpeg = try FFTools.ffmpegURL()
        let ext = settings.container.fileExtension
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidconform-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let wantsAudio = settings.type != .videoOnly

        // 1. Produce each clip's video piece per its M2 plan — re-encode the head/tail
        //    edges, stream-copy the keyframe-bounded middle, concat (ADR-0009). The bulk
        //    of the work, and the only part that re-encodes.
        var videoPieces: [URL] = []
        if wantsVideo {
            for (i, item) in items.enumerated() {
                videoPieces.append(try await BoundaryReencodeEngine.produceVideoPiece(
                    ffmpeg, source: item.source, plan: item.segments, index: item.index,
                    encoder: item.encoder, work: work, ext: ext, clipIndex: i))
                progress(0.7 * Double(i + 1) / Double(items.count))
            }
        }

        // 2. Assemble the output(s).
        switch settings.mode {
        case .connect:
            var videoInput: URL? = nil
            if wantsVideo {
                if videoPieces.count == 1 {
                    videoInput = videoPieces[0]
                } else {
                    let joined = work.appendingPathComponent("joined_video.\(ext)")
                    try await concatVideo(ffmpeg, pieces: videoPieces, to: joined, work: work)
                    videoInput = joined
                }
            }
            if wantsAudio {
                try await runFFmpeg(ffmpeg, audioMuxArguments(videoInput: videoInput, items: items, output: destination),
                                    failure: ExportError.concatFailed)
            } else {
                try placeFile(videoInput!, at: destination)
            }

        case .separate:
            for (i, item) in items.enumerated() {
                let out = separateURL(destination: destination, index: i, count: items.count, ext: ext)
                let videoInput = wantsVideo ? videoPieces[i] : nil
                if wantsAudio {
                    try await runFFmpeg(ffmpeg, audioMuxArguments(videoInput: videoInput, items: [item], output: out),
                                        failure: ExportError.cutFailed)
                } else {
                    try placeFile(videoInput!, at: out)
                }
                progress(0.7 + 0.3 * Double(i + 1) / Double(items.count))
            }
        }
        progress(1.0)
    }

    private static func concatVideo(_ ffmpeg: URL, pieces: [URL], to output: URL, work: URL) async throws {
        let listFile = work.appendingPathComponent("concat-\(UUID().uuidString).txt")
        try concatListContents(pieces: pieces).write(to: listFile, atomically: true, encoding: .utf8)
        try await runFFmpeg(ffmpeg, concatArguments(listFile: listFile, output: output), failure: ExportError.concatFailed)
    }

    /// Destination for one clip in `.separate` mode: the chosen name for a single clip,
    /// else `name-1.ext`, `name-2.ext`, …
    private static func separateURL(destination: URL, index i: Int, count: Int, ext: String) -> URL {
        let dir = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent
        let name = count == 1 ? "\(stem).\(ext)" : "\(stem)-\(i + 1).\(ext)"
        return dir.appendingPathComponent(name)
    }

    /// Moves a produced file to its destination, replacing any existing file.
    private static func placeFile(_ src: URL, at dest: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: src, to: dest)
    }

    /// Runs ffmpeg and turns a non-zero exit into `failure(stderr)`.
    private static func runFFmpeg(_ ffmpeg: URL, _ args: [String], failure: (String) -> ExportError) async throws {
        let result = try await ProcessRunner.run(ffmpeg, args)
        guard result.status == 0 else {
            throw failure(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
    }
}
