import Foundation

/// One clip's contribution to an export: where it lives and the Milestone 2 plan of what
/// to keep (ADR-0009) — an ordered list of copy / re-encode `segments` over `index`,
/// produced with `encoder` (the source-matched re-encode args). `codec` is the ffprobe
/// `codec_name`, used to refuse a stream-copy concat across different codecs (that is
/// conform — a later milestone).
///
/// `audioStart`/`audioEnd` are the clip's kept range as **input-seek seconds** — measured
/// from the container's start_time, i.e. `pts − start_time` (`keptWindow`; issue #3) —
/// the audio is re-encoded over exactly this window so it stays aligned with the video
/// and the joins are gap-free (ADR-0008). `nil` means that end is the clip boundary (no
/// cut there).
struct ExportItem {
    var source: URL
    /// The clip's display name, used to name this clip's file in `.separate` mode
    /// (`NN <clip name>.<ext>`, issue #30).
    var displayName: String = ""
    var codec: String? = nil
    var segments: [PlannedSegment] = []
    var index: FrameIndex = FrameIndex(pts: [], keyframeFlags: [])
    var encoder: [String] = []
    var audioStart: Double? = nil
    var audioEnd: Double? = nil
    /// What feeds each of this clip's audio legs, by output track (ADR-0014): the clip's
    /// own Nth audio stream, an external file, or `nil` for silence. Output tracks past
    /// the end of this list are silence too.
    var audioSources: [ExportEngine.AudioSource?] = [.stream(0)]
    /// The clip's kept video duration in seconds — every audio leg is trimmed/padded to
    /// exactly this many samples so the output tracks can't drift apart at joins
    /// (ADR-0014). Falls back to `audioEnd - audioStart` when unset.
    var audioDuration: Double? = nil
    /// Set when this clip does not match the target and its video must be fully re-encoded to
    /// the target spec (ADR-0011). When present the clip is conformed instead of smart-rendered,
    /// and `segments` is unused; `nil` for a matching clip (the M2 smart-render path).
    var conform: ConformEngine.VideoConform? = nil
    /// Cut-only (ADR-0018): this clip's own output tracks — exactly its selected slots,
    /// each possibly carrying its own encoder — overriding the export-wide track list in
    /// `.separate` mode. `nil` (every other mode) means the export-wide tracks apply.
    var ownTracks: [AudioCodecPolicy.OutputAudioTrack]? = nil
}

enum ExportError: LocalizedError {
    case noClips
    case invalidPlan
    case unsupportedContainer(codec: String, container: String)
    case cutFailed(String)
    case conformFailed(String)
    case concatFailed(String)
    case missingSegment
    case verificationFailed(String)
    /// The user cancelled (issue #32) — not a failure. Carries how many `.separate`
    /// files had already finished (and stay on disk) so the status line can say so.
    case cancelled(finished: Int, total: Int)

    var errorDescription: String? {
        switch self {
        case .noClips: return "There are no clips to export."
        case .invalidPlan: return "A clip's in/out points collapse to nothing after snapping to clean cut points."
        case .unsupportedContainer(let codec, let container):
            return "The \(container.uppercased()) container can't carry \(codec) video by stream-copy. Choose TS (recommended for this footage) or MP4."
        case .cutFailed(let d): return "Could not cut a clip.\n\(d)"
        case .conformFailed(let d): return "Could not conform a clip to the target.\n\(d)"
        case .concatFailed(let d): return "Could not join the clips.\n\(d)"
        case .missingSegment: return "The expected output segment was not produced."
        case .verificationFailed(let d): return "The cut did not verify and was not saved.\n\(d)"
        case .cancelled: return "The export was cancelled."
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
    private static let audioBitrate = "192k"

    /// What feeds one audio leg (ADR-0014).
    enum AudioSource: Equatable {
        /// The clip's own file's Nth audio stream (0-based).
        case stream(Int)
        /// The Nth audio stream of an external file (audio-only or another video),
        /// aligned file start = video-file start, so the clip's kept window cuts the
        /// same span out of it.
        case external(URL, stream: Int)
    }

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
    ///
    /// `durations` (one optional entry per piece, aligned by index) adds a `duration
    /// <seconds>` directive after a piece's `file` line. That pins how far the demuxer
    /// advances the timeline before the *next* piece, overriding the container-reported
    /// duration. It matters because a stream-copied head piece that kept the source's
    /// non-zero `start_time` reports a duration inflated by that leading offset (the MKV/MP4
    /// duration field measures from zero, so it includes the gap before the first frame);
    /// the demuxer would then place the following piece one slot late and open a gap at the
    /// seam (the start_time off-by-one, ADR-0008). The true span — `pts[upperBound] -
    /// pts[lowerBound]` of the piece's kept frames — closes it. Container-agnostic: on a TS
    /// piece, whose offset the mpegts muxer already normalises uniformly, the directive
    /// equals the real span and changes nothing (verified on H.264/MPEG-2/HEVC in the shell).
    /// An omitted/`nil` entry emits no directive — the default (`[]`) reproduces the bare list.
    static func concatListContents(pieces: [URL], durations: [Double?] = []) -> String {
        var lines: [String] = []
        for (i, piece) in pieces.enumerated() {
            lines.append("file '\(piece.path.replacingOccurrences(of: "'", with: "'\\''"))'")
            if i < durations.count, let d = durations[i], d > 0 {
                lines.append("duration \(timeString(d))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The timeline span (seconds) each clip's video piece should occupy in the **cross-clip**
    /// concat — the `duration` directives fed to `concatListContents`, closing the same
    /// start_time seam gap `BoundaryReencodeEngine.segmentSpans` closes inside a clip
    /// (issue #6). The biting piece is a single-copy-segment clip trimmed only at its tail
    /// (segment 0 of the muxer cut keeps the source's non-zero start_time; an MKV piece's
    /// container duration then includes that leading offset and the next clip lands late).
    /// De-risked in the shell on H.264/HEVC/MPEG-2: the cross-clip gap shows in MKV only
    /// (unlike the within-clip case, the MP4 piece's duration matched its true span —
    /// noted in ADR-0008), and the directive closes it; on MP4/TS pieces — and every
    /// internally-normalized piece — the directive equals the real span and is a no-op.
    ///
    /// A smart-rendered clip's span comes from its plan: the segments tile the kept range
    /// `[lo, hi)` contiguously, so the span is `pts[hi] - pts[lo]` — exact when the clip is
    /// trimmed (`hi` is a real frame). When it runs to the clip end (`hi == count`,
    /// `pts[hi]` out of bounds) the last frame's slot is estimated from the mean frame
    /// interval — safe because no piece ships with non-uniform spacing anyway (the
    /// `timestampDefect` self-check in `verifyPiece`). A conformed clip re-encodes its kept window
    /// to the target spec preserving duration, so its span is the kept duration the app
    /// supplies. The last clip offsets nothing → `nil`; an uncomputable span degrades to
    /// `nil` (no directive — today's behavior) rather than guessing.
    static func clipSpans(items: [ExportItem]) -> [Double?] {
        items.enumerated().map { i, item in
            i < items.count - 1 ? clipSpan(item) : nil
        }
    }

    /// One clip's kept video span in seconds (see `clipSpans`).
    static func clipSpan(_ item: ExportItem) -> Double? {
        if item.conform != nil { return keptDuration(item) }
        guard let first = item.segments.first, let last = item.segments.last else { return nil }
        let pts = item.index.pts
        let lo = first.range.lowerBound, hi = last.range.upperBound
        guard lo < pts.count, hi <= pts.count else { return nil }
        if hi < pts.count { return pts[hi] - pts[lo] }
        guard pts.count >= 2 else { return nil }
        let interval = (pts[pts.count - 1] - pts[0]) / Double(pts.count - 1)
        return pts[pts.count - 1] - pts[lo] + interval
    }

    /// Inspects a produced piece's presentation timestamps (sorted ascending) for the two
    /// timestamp defects this engine has shipped: a **duplicate** PTS (two frames sharing a
    /// timestamp — the B-pyramid/MKV stream-copy collapse, ADR-0011) and a **seam gap** (a
    /// frame slot skipped — the start_time concat offset, ADR-0008). Within one produced
    /// piece the frame rate is constant, so a clean piece is near-uniformly spaced: an
    /// interval at or below half the median is a duplicate, at or above 1.5× is a gap. The
    /// generous band tolerates float jitter while still catching a whole missing/collapsed
    /// frame. Returns a human-readable reason, or `nil` when clean (or too short to judge).
    /// Pure, so it is unit-tested against captured-defect timestamps; the export engines run
    /// it as a final self-check before a piece ships, so neither defect can slip out silently.
    static func timestampDefect(pts: [Double]) -> String? {
        guard pts.count >= 3 else { return nil }
        let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }
        let median = deltas.sorted()[deltas.count / 2]
        guard median > 0 else { return "frames share a timestamp (zero median interval)" }
        for (i, d) in deltas.enumerated() {
            if d <= median * 0.5 {
                return String(format: "frames at %.3fs and %.3fs are only %.4fs apart (~%.4fs expected — a duplicate)",
                              pts[i], pts[i + 1], d, median)
            }
            if d >= median * 1.5 {
                return String(format: "a %.4fs gap between %.3fs and %.3fs (~%.4fs expected — a frame slot was skipped)",
                              d, pts[i], pts[i + 1], median)
            }
        }
        return nil
    }

    /// A clip's kept range as ffmpeg sees it: `start`/`end` are input-seek seconds —
    /// measured from the **container's start_time**, not absolute pts (ADR-0015) —
    /// and `duration` is the kept video span used to force every audio leg's length.
    struct KeptWindow: Equatable {
        var start: Double?
        var end: Double?
        var duration: Double
    }

    /// Converts a clip's kept range from frame-index pts (absolute presentation time)
    /// to the seek window the ffmpeg invocations need. ffmpeg's input `-ss` counts from
    /// the container's start_time, so passing absolute pts lands `containerStart`
    /// seconds late in content on a non-zero-start file (measured +230 ms audio-ahead
    /// on the MPEG-PS test clip — issue #3); the seek values subtract it. The duration
    /// stays in absolute pts: first/last frame fill open ends, and the last frame
    /// displays for one frame beyond its pts.
    static func keptWindow(inPts: Double?, outPts: Double?, firstPts: Double?,
                           lastPts: Double?, frameDuration: Double?, containerStart: Double) -> KeptWindow {
        let spanStart = inPts ?? firstPts ?? 0
        let spanEnd = outPts ?? ((lastPts ?? 0) + (frameDuration ?? 0))
        return KeptWindow(start: inPts.map { $0 - containerStart },
                          end: outPts.map { $0 - containerStart },
                          duration: max(0, spanEnd - spanStart))
    }

    /// Input args selecting one clip's audio source range: a fast seek to `start` and a
    /// read duration. `-ss`/`-t` before `-i` are input options. An open start/end omits
    /// the corresponding flag (read from the file start / to the file end). `start`/`end`
    /// are input-seek seconds (`KeptWindow`), never absolute pts.
    static func audioInputArgs(source: URL, start: Double?, end: Double?) -> [String] {
        var a: [String] = []
        if let start { a += ["-ss", timeString(start)] }
        if let end { a += ["-t", timeString(end - (start ?? 0))] }
        a += ["-i", source.path]
        return a
    }

    /// A clip's kept duration in seconds — the length every one of its audio legs is
    /// forced to. The app supplies it explicitly; the closed window is the fallback.
    private static func keptDuration(_ item: ExportItem) -> Double? {
        if let d = item.audioDuration, d > 0 { return d }
        guard let s = item.audioStart, let e = item.audioEnd, e > s else { return nil }
        return e - s
    }

    /// Final-mux args (ADR-0014): copy `videoInput`'s video (when present) and rebuild N
    /// continuous audio tracks — one sample-level concat chain per output track. Every
    /// leg is conformed to its track's rate/layout and forced to the clip's exact kept
    /// duration in samples (`atrim`+`apad` — tracks of one clip decode to slightly
    /// different lengths otherwise, and the output tracks would drift apart at every
    /// join). A clip with no source for a track contributes `anullsrc` silence in the
    /// track's format. `videoInput` is `nil` for an audio-only export.
    static func audioMuxArguments(videoInput: URL?, items: [ExportItem], tracks: [AudioCodecPolicy.OutputAudioTrack],
                                  audioCodec: String, output: URL) -> [String] {
        // -y: an existing file at the destination is overwritten silently — the
        // save panel's "Replace" already said yes, and `.separate` mode promises
        // re-exports land in place (issue #30).
        var args = ["-y", "-v", "error"]
        var nextInput = 0
        if let videoInput {
            args += ["-i", videoInput.path]
            nextInput = 1
        }
        // One input per clip, plus one per distinct external audio file a clip uses.
        // An external file gets the same seek window as the clip — it is aligned
        // file start = video-file start (ADR-0014), like a stream of the clip's own file.
        var ownInput: [Int] = []
        var externalInput: [[URL: Int]] = []
        for item in items {
            args += audioInputArgs(source: item.source, start: item.audioStart, end: item.audioEnd)
            ownInput.append(nextInput)
            nextInput += 1
            var externals: [URL: Int] = [:]
            for case .external(let url, _)? in item.audioSources where externals[url] == nil {
                args += audioInputArgs(source: url, start: item.audioStart, end: item.audioEnd)
                externals[url] = nextInput
                nextInput += 1
            }
            externalInput.append(externals)
        }

        var chains: [String] = []
        for (t, track) in tracks.enumerated() {
            var labels: [String] = []
            for (i, item) in items.enumerated() {
                let label = "[c\(i)t\(t)]"
                let samples = keptDuration(item).map { Int(($0 * Double(track.sampleRate)).rounded()) }
                let layout = ConformEngine.channelLayout(track.channels)
                let source = t < item.audioSources.count ? item.audioSources[t] : nil
                switch source {
                case .stream(let s):
                    chains.append("[\(ownInput[i]):a:\(s)]" + legFilter(track: track, samples: samples) + label)
                case .external(let url, let s):
                    chains.append("[\(externalInput[i][url]!):a:\(s)]" + legFilter(track: track, samples: samples) + label)
                case nil:
                    chains.append("anullsrc=r=\(track.sampleRate):cl=\(layout),atrim=end_sample=\(samples ?? 0)" + label)
                }
                labels.append(label)
            }
            chains.append("\(labels.joined())concat=n=\(items.count):v=0:a=1[a\(t)]")
        }

        if !chains.isEmpty { args += ["-filter_complex", chains.joined(separator: ";")] }
        if videoInput != nil { args += ["-map", "0:v:0", "-c:v", "copy"] }
        for t in tracks.indices { args += ["-map", "[a\(t)]"] }
        if !tracks.isEmpty {
            if tracks.contains(where: { $0.encoder != nil }) {
                // Cut-only (ADR-0018): tracks of one output can encode to different
                // codecs, so each gets its own `-c:a:N` (de-risked in the shell on all
                // three formats in TS/MKV/MP4). A track without its own encoder takes
                // the export-wide codec.
                for (t, track) in tracks.enumerated() {
                    args += ["-c:a:\(t)", track.encoder ?? audioCodec]
                }
                args += ["-b:a", audioBitrate]
            } else {
                args += ["-c:a", audioCodec, "-b:a", audioBitrate]
            }
        }
        for (t, track) in tracks.enumerated() {
            if let language = track.language { args += ["-metadata:s:a:\(t)", "language=\(language)"] }
            if let title = track.title { args += ["-metadata:s:a:\(t)", "title=\(title)"] }
        }
        args.append(output.path)
        return args
    }

    /// One real audio leg's filter: conform to the track's rate/layout, then force the
    /// exact kept length — trim the overshoot, silence-pad the shortfall.
    private static func legFilter(track: AudioCodecPolicy.OutputAudioTrack, samples: Int?) -> String {
        var f = ConformEngine.audioFilter(sampleRate: track.sampleRate, channels: track.channels)
        if let n = samples { f += ",atrim=end_sample=\(n),apad=whole_len=\(n)" }
        return f
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
    /// `settings`, rebuilding the audio track when the output includes audio. In
    /// `.connect` mode `destination` is the file the user chose; in `.separate` mode it
    /// is the **folder** they chose, and each clip is written into it as
    /// `NN <clip name>.<ext>` in timeline order (issue #30), silently overwriting any
    /// existing file of the same name. `progress` reports 0…1, smoothed within each ffmpeg
    /// run from its `-progress` out_time (issue #9) and keeping the established 70 % video
    /// / 30 % audio phase split; it can be called from a background queue mid-run.
    static func export(
        items: [ExportItem],
        settings: OutputSettings,
        audioCodec: String = AudioCodecPolicy.fallbackAudioCodec,
        tracks: [AudioCodecPolicy.OutputAudioTrack] = [AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2)],
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard !items.isEmpty else { throw ExportError.noClips }
        let wantsVideo = settings.type != .audioOnly
        if wantsVideo {
            // A clip is valid if it has an M2 smart-render plan or is being conformed (ADR-0011).
            guard items.allSatisfy({ !$0.segments.isEmpty || $0.conform != nil }) else {
                throw ExportError.invalidPlan
            }
        }
        // No mixed-codec refusal: a non-matching clip is conformed to the target's codec
        // (ADR-0011), so every piece reaching the concat is already the target codec.
        for item in items where !streamCopyCompatible(codec: item.codec, container: settings.container) {
            throw ExportError.unsupportedContainer(codec: item.codec ?? "this", container: settings.container.fileExtension)
        }

        let ffmpeg = try FFTools.ffmpegURL()
        // Video pieces always use the container extension; an audio-only output has no video
        // pieces and is written as an audio-elementary file (ADR-0010 / #1).
        let ext = AudioCodecPolicy.outputExtension(type: settings.type, container: settings.container, audioEncoder: audioCodec)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidconform-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let wantsAudio = settings.type != .videoOnly

        // A cancel (issue #32) discards the file being written but keeps `.separate`
        // files that already finished — they are valid exports. Both are tracked here
        // so the catch below can act on them; the temp work dir is cleaned by the
        // defer like on any exit.
        var currentOutput: URL? = nil
        var finishedFiles = 0
        do {
        // 1. Produce each clip's video piece per its M2 plan — re-encode the head/tail
        //    edges, stream-copy the keyframe-bounded middle, concat (ADR-0009). The bulk
        //    of the work, and the only part that re-encodes.
        //    A non-matching clip is instead conformed: a full re-encode of its kept range to
        //    the target spec, self-verified before it ships (ADR-0011).
        var videoPieces: [URL] = []
        if wantsVideo {
            for (i, item) in items.enumerated() {
                let withinClip: @Sendable (Double) -> Void = { w in
                    progress(ExportProgress.clipFraction(clipIndex: i, clipCount: items.count, withinClip: w))
                }
                if let conform = item.conform {
                    videoPieces.append(try await ConformEngine.produceConformedPiece(
                        ffmpeg, source: item.source, conform: conform,
                        start: item.audioStart, end: item.audioEnd, work: work, ext: ext, clipIndex: i,
                        onProgress: withinClip))
                } else {
                    videoPieces.append(try await BoundaryReencodeEngine.produceVideoPiece(
                        ffmpeg, source: item.source, plan: item.segments, index: item.index,
                        encoder: item.encoder, work: work, ext: ext, clipIndex: i,
                        onProgress: withinClip))
                }
                progress(0.7 * Double(i + 1) / Double(items.count))
            }
        }
        // The audio rebuild's expected output length: the clips' combined kept duration
        // (unknown if any clip lacks one — the mux fraction then just holds at 70 %).
        let totalSpan: Double? = items.reduce(0.0 as Double?) { acc, item in
            guard let acc, let d = keptDuration(item) else { return nil }
            return acc + d
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
                    try await concatVideo(ffmpeg, pieces: videoPieces, items: items, to: joined, work: work)
                    videoInput = joined
                }
            }
            currentOutput = destination
            if wantsAudio {
                try await runFFmpeg(ffmpeg, audioMuxArguments(videoInput: videoInput, items: items, tracks: tracks, audioCodec: audioCodec, output: destination),
                                    failure: ExportError.concatFailed) { t in
                    progress(ExportProgress.muxFraction(
                        withinMux: ExportProgress.runFraction(outTime: t, expectedSeconds: totalSpan)))
                }
            } else {
                try placeFile(videoInput!, at: destination)
            }

        case .separate:
            // Cut-only's audio-only outputs can differ per clip (each clip's own codec,
            // each codec its natural elementary extension); video outputs all take the
            // global container's extension.
            let exts = items.map { item in
                settings.type == .audioOnly
                    ? AudioCodecPolicy.audioFileExtension(forEncoder: item.ownTracks?.first?.encoder ?? audioCodec)
                    : ext
            }
            let names = separateFileNames(clipNames: items.map(\.displayName), exts: exts)
            for (i, item) in items.enumerated() {
                let out = destination.appendingPathComponent(names[i])
                let videoInput = wantsVideo ? videoPieces[i] : nil
                let itemTracks = item.ownTracks ?? tracks
                currentOutput = out
                if wantsAudio {
                    try await runFFmpeg(ffmpeg, audioMuxArguments(videoInput: videoInput, items: [item], tracks: itemTracks, audioCodec: audioCodec, output: out),
                                        failure: ExportError.cutFailed) { t in
                        progress(ExportProgress.separateFraction(
                            clipIndex: i, clipCount: items.count,
                            withinMux: ExportProgress.runFraction(outTime: t, expectedSeconds: keptDuration(item))))
                    }
                } else {
                    try placeFile(videoInput!, at: out)
                }
                currentOutput = nil
                finishedFiles = i + 1
                progress(0.7 + 0.3 * Double(i + 1) / Double(items.count))
            }
        }
        } catch is CancellationError {
            // The mid-write file is partial — discard it. Finished separate files stay.
            if let currentOutput { try? FileManager.default.removeItem(at: currentOutput) }
            throw ExportError.cancelled(
                finished: finishedFiles,
                total: settings.mode == .separate ? items.count : 1)
        }
        progress(1.0)
    }

    private static func concatVideo(_ ffmpeg: URL, pieces: [URL], items: [ExportItem], to output: URL, work: URL) async throws {
        let listFile = work.appendingPathComponent("concat-\(UUID().uuidString).txt")
        try concatListContents(pieces: pieces, durations: clipSpans(items: items))
            .write(to: listFile, atomically: true, encoding: .utf8)
        try await runFFmpeg(ffmpeg, concatArguments(listFile: listFile, output: output), failure: ExportError.concatFailed)
    }

    /// File names for `.separate` mode, one per clip in timeline order (issue #30):
    /// `NN <clip name>.<ext>` — `NN` is the 1-based position zero-padded to the digit
    /// count of the clip total (minimum two, so Finder's alphabetical sort is the
    /// timeline order even as clips are added later).
    static func separateFileNames(clipNames: [String], ext: String) -> [String] {
        separateFileNames(clipNames: clipNames, exts: Array(repeating: ext, count: clipNames.count))
    }

    /// Per-clip-extension variant: cut-only audio-only outputs follow each clip's own
    /// codec, so their extensions can differ within one export (ADR-0018).
    static func separateFileNames(clipNames: [String], exts: [String]) -> [String] {
        var taken = Set<String>()
        return clipNames.enumerated().map { i, name in
            separateFileName(clipName: name, position: i + 1, count: clipNames.count,
                             ext: exts[i], taken: &taken)
        }
    }

    /// One `.separate`-mode file name: the clip's display name loses its source
    /// extension, `/` and `:` become `-` (the two characters the filesystem and Finder
    /// fight over), and the padded position is prefixed — always, even for a single
    /// clip, so the names sort predictably. Distinct prefixes make collisions
    /// impossible, but if one happens anyway a `-2`, `-3`, … suffix keeps the names
    /// unique rather than silently merging two clips into one file.
    static func separateFileName(clipName: String, position: Int, count: Int,
                                 ext: String, taken: inout Set<String>) -> String {
        var stem = (clipName as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if stem.isEmpty { stem = "Clip" }
        let width = max(2, String(count).count)
        let prefix = String(format: "%0\(width)d", position)
        var name = "\(prefix) \(stem).\(ext)"
        var n = 2
        while taken.contains(name) {
            name = "\(prefix) \(stem)-\(n).\(ext)"
            n += 1
        }
        taken.insert(name)
        return name
    }

    /// Moves a produced file to its destination, replacing any existing file.
    private static func placeFile(_ src: URL, at dest: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: src, to: dest)
    }

    /// Runs ffmpeg and turns a non-zero exit into `failure(stderr)`. With `onOutTime` the
    /// run also streams `-progress pipe:1` (issue #9), reporting each block's out_time
    /// seconds as it arrives.
    private static func runFFmpeg(_ ffmpeg: URL, _ args: [String], failure: (String) -> ExportError,
                                  onOutTime: (@Sendable (Double) -> Void)? = nil) async throws {
        let result: ProcessResult
        if let onOutTime {
            let parser = ProgressParser()
            result = try await ProcessRunner.run(ffmpeg, ExportProgress.progressArguments(args)) { chunk in
                if let t = parser.feed(chunk) { onOutTime(t) }
            }
        } else {
            result = try await ProcessRunner.run(ffmpeg, args)
        }
        guard result.status == 0 else {
            throw failure(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
    }
}
