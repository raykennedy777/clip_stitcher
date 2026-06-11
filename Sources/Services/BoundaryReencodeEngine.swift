import Foundation

/// Milestone 2 export executor (ADR-0009): produces a frame-exact between-keyframes cut
/// by re-encoding the partial head/tail GOPs and stream-copying the keyframe-bounded
/// middle, then concatenating — the recipe validated frame-exact against real
/// H.264/HEVC/MPEG-2 footage in the shell. It executes a `BoundaryReencodePlanner` plan
/// with the bundled ffmpeg CLI only; no in-process libav (ADR-0002).
///
/// The argument builders are pure so the exact command shape can be unit-tested.
enum BoundaryReencodeEngine {
    /// ffmpeg video-encode args matched to the source so the re-encoded GOPs concat
    /// cleanly with the copied middle (ADR-0009): same codec family, pixel format, and
    /// — when it maps to a known encoder profile — the source's profile; plus, for
    /// interlaced MPEG-2, the field flags that preserve `field_order`. SAR is carried
    /// through by ffmpeg automatically, so no `-aspect` is needed (verified).
    ///
    /// In practice the pixel format already pins the profile for the common cases
    /// (yuv420p10le ⇒ libx265 main10, yuv420p ⇒ libx264 high / mpeg2 main — all verified
    /// against the real footage). `-profile:v` is added for robustness so an *unusual*
    /// source (e.g. a Baseline H.264 clip that would otherwise re-encode to High) still
    /// matches; an unrecognised profile string is omitted rather than guessed, leaving the
    /// encoder's working inference in place.
    static func reencodeVideoArgs(
        codec: String?, profile: String? = nil, pixelFormat: String?, fieldOrder: String?
    ) -> [String] {
        let pixFmt = pixelFormat ?? "yuv420p"
        var args = ["-c:v", EncoderSelection.encoder(for: codec), "-pix_fmt", pixFmt]
        if let p = EncoderSelection.encoderProfile(profile, codec: EncoderSelection.profileCodec(for: codec)) {
            args += ["-profile:v", p]
        }
        if codec == "mpeg2video" {
            switch fieldOrder {
            case "tt", "tb": args += ["-flags", "+ildct+ilme", "-top", "1"]
            case "bb", "bt": args += ["-flags", "+ildct+ilme", "-top", "0"]
            default: break   // progressive / unknown — no interlace flags
            }
        }
        return args
    }

    /// ffmpeg args to re-encode the partial-GOP presentation range `[range.lowerBound,
    /// range.upperBound)` into `output`. To avoid decoding the whole file, it input-seeks
    /// to the keyframe at/before the range start (which the decoder emits as `n = 0`),
    /// then selects frames RELATIVE to that keyframe. The seek is start_time-relative
    /// (ffmpeg subtracts the stream start_time from `-ss`), so the first presentation PTS
    /// is removed. Audio is dropped here; the rebuilt track is muxed in later.
    ///
    /// `-frames:v <range.count>` ends the run at the last kept frame: `select` only
    /// *drops* frames, so without a frame budget ffmpeg keeps decoding from the range's
    /// end to the file's end emitting nothing — on a 72-minute HEVC source that pinned
    /// the CPU for many extra minutes after a 28 s cut, with the encoder's lookahead
    /// not even flushing until that pointless decode hit EOF (test_sprint diagnosis).
    /// De-risked on all three formats: identical frames, the run just stops on time.
    ///
    /// An MP4 piece also pins `-video_track_timescale` to the source's (issue #18): the
    /// concat demuxer reads every listed file in one timebase, and the encoder-default
    /// 1/12800 track otherwise lands mis-scaled next to the source-inherited copy piece,
    /// collapsing the re-encode's frames when the mp4 muxer "repairs" the resulting
    /// non-monotonic DTS. MKV/TS impose a fixed per-container timebase, so the flag is
    /// only emitted for an mp4 output; an unknown timescale omits it rather than guessing.
    static func reencodeSegmentArguments(
        source: URL, range: Range<Int>, index: FrameIndex, encoder: [String], output: URL,
        trackTimescale: Int? = nil
    ) -> [String] {
        let anchor = index.keyframeIndex(atOrBefore: range.lowerBound)
        let startOffset = index.pts.first ?? 0
        let seek = index.pts[anchor] - startOffset
        let relStart = range.lowerBound - anchor
        let relEnd = range.upperBound - 1 - anchor
        var args = ["-v", "error", "-ss", ExportEngine.timeString(seek), "-i", source.path]
        args += ["-vf", "select='between(n\\,\(relStart)\\,\(relEnd))',setpts=PTS-STARTPTS"]
        args += encoder
        if let trackTimescale, output.pathExtension.lowercased() == "mp4" {
            args += ["-video_track_timescale", String(trackTimescale)]
        }
        args += ["-frames:v", String(range.count), "-an", output.path]
        return args
    }

    /// ffmpeg args producing the **timescale probe piece** (issue #18): one stream-copied
    /// video packet muxed into MP4, whose track timescale is then read back as the value
    /// the clip's real copy pieces will carry. Measured, never derived from the source:
    /// the mp4 muxer auto-raises an MKV's coarse 1/1000 stream timebase to 1/16000 on
    /// copy (verified in the shell), so the source's own probed timebase is not the answer.
    static func timescaleProbeArguments(source: URL, output: URL) -> [String] {
        ["-v", "error", "-i", source.path, "-map", "0:v:0",
         "-c", "copy", "-frames:v", "1", output.path]
    }

    /// The MP4 track timescale a re-encoded piece must pin (issue #18), from the timescale
    /// probe piece's `time_base` ("1/16000" ⇒ 16000; ffprobe's csv writer leaves a trailing
    /// comma on MPEG-2 streams, so commas are stripped). Only a unit-numerator timebase
    /// maps to a track timescale; anything else returns `nil` and the flag is omitted
    /// rather than guessed (the export then behaves exactly as before #18).
    static func trackTimescale(timeBase: String?) -> Int? {
        let cleaned = (timeBase ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ", \n"))
        let parts = cleaned.split(separator: "/")
        guard parts.count == 2, parts[0] == "1",
              let den = Int(parts[1]), den > 0 else { return nil }
        return den
    }

    /// Maps a copy segment `[copyRange.lowerBound, copyRange.upperBound)` onto a
    /// `SegmentPlan` so its validated segment-muxer cut/remux can stream-copy the span
    /// bit-exact. A bound that is a clip boundary (frame 0 / no out-cut keyframe) gets no
    /// cut at that end — copy from the file start / to the file end — and a span touching
    /// neither boundary becomes a two-cut plan whose wanted piece is the middle. The cut
    /// times are start_time-corrected DTS midpoints (ADR-0008).
    ///
    /// The out-cut anchors at the plan's `outCutKeyframe`, not the range's upper bound:
    /// on an open-GOP end the range stops `n_leading` frames before the keyframe (#16),
    /// but it is still the cut before the *keyframe's* DTS that produces it — the
    /// keyframe's leading pictures land in the discarded segment.
    static func copySegmentPlan(
        copyRange: Range<Int>, outCutKeyframe: Int?, index: FrameIndex
    ) -> SegmentPlan {
        let needsInCut = copyRange.lowerBound > 0
        return SegmentPlan(
            inFrame: copyRange.lowerBound,
            outFrame: copyRange.upperBound,
            inSegmentTime: needsInCut ? index.segmentTime(forCutAt: copyRange.lowerBound) : nil,
            outSegmentTime: outCutKeyframe.map { index.segmentTime(forCutAt: $0) }
        )
    }

    // MARK: - Orchestration

    /// Executes a Milestone 2 plan for one clip into a single **video** piece in `work`
    /// and returns it. Each re-encode segment is a frame-selected encode; each copy
    /// segment is M1's segment-muxer cut/remux; the pieces are concatenated in plan order
    /// (a single-segment plan needs no concat). Audio is rebuilt separately, as in M1.
    ///
    /// `onProgress` reports 0…1 across the clip's segment runs (issue #9), weighted by
    /// frame count and smoothed within each run by ffmpeg's out_time against the run's
    /// expected output: a re-encode produces its segment's span, while a segment-muxer
    /// cut (and a whole-clip remux) reads/writes the whole source span regardless of the
    /// wanted piece. The closing concat and verify aren't instrumented — the bar holds
    /// at the clip's top edge while they run.
    static func produceVideoPiece(
        _ ffmpeg: URL, source: URL, plan: [PlannedSegment], index: FrameIndex,
        encoder: [String], work: URL, ext: String, clipIndex: Int, codec: String? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard !plan.isEmpty else { throw ExportError.invalidPlan }
        // mpeg2video→MKV copy needs the missing-PTS refill (issue #2); [] otherwise.
        let bsf = ExportEngine.ptsRefillBitstreamFilter(codec: codec, ext: ext)

        // An MP4 plan mixing copy and re-encode pieces must mux them in one track
        // timescale (issue #18): measure what the copy pieces will inherit via the
        // one-packet timescale probe, and pin the re-encodes to it. An unreadable
        // probe leaves the pin off — the verify gates still backstop the seam.
        var pieceTimescale: Int? = nil
        if ext.lowercased() == "mp4",
           plan.contains(where: { $0.kind == .copy }),
           plan.contains(where: { $0.kind == .reEncode }) {
            let probe = work.appendingPathComponent("c\(clipIndex)_tsprobe.mp4")
            try await run(ffmpeg, timescaleProbeArguments(source: source, output: probe))
            pieceTimescale = trackTimescale(timeBase: await MediaProbe.videoTimeBase(url: probe))
        }

        let segmentFrames = plan.map { $0.range.count }
        let interval = meanFrameInterval(index)
        let sourceSpan = interval.flatMap { i in
            index.pts.last.map { $0 - index.pts[0] + i }
        }

        var pieces: [URL] = []
        for (s, segment) in plan.enumerated() {
            let expected: Double?
            switch segment.kind {
            case .reEncode: expected = interval.map { Double(segment.range.count) * $0 }
            case .copy: expected = sourceSpan
            }
            let onOutTime: @Sendable (Double) -> Void = { t in
                onProgress(ExportProgress.withinClip(
                    segmentFrames: segmentFrames, completedSegments: s,
                    currentRunFraction: ExportProgress.runFraction(outTime: t, expectedSeconds: expected)))
            }
            let piece: URL
            switch segment.kind {
            case .reEncode:
                piece = work.appendingPathComponent("c\(clipIndex)_s\(s)_re.\(ext)")
                try await run(ffmpeg, reencodeSegmentArguments(
                    source: source, range: segment.range, index: index,
                    encoder: encoder, output: piece, trackTimescale: pieceTimescale),
                    onOutTime: onOutTime)
            case .copy:
                let copyPlan = copySegmentPlan(
                    copyRange: segment.range, outCutKeyframe: segment.outCutKeyframe, index: index)
                if ExportEngine.needsCut(copyPlan) {
                    let pattern = work.appendingPathComponent("c\(clipIndex)_s\(s)_cp_%03d.\(ext)").path
                    try await run(ffmpeg, ExportEngine.cutArguments(
                        source: source, plan: copyPlan, segmentPattern: pattern,
                        bitstreamFilter: bsf), onOutTime: onOutTime)
                    piece = work.appendingPathComponent(String(
                        format: "c\(clipIndex)_s\(s)_cp_%03d.\(ext)",
                        ExportEngine.wantedSegmentIndex(plan: copyPlan)))
                } else {
                    piece = work.appendingPathComponent("c\(clipIndex)_s\(s)_cp.\(ext)")
                    try await run(ffmpeg, ExportEngine.remuxArguments(
                        source: source, output: piece, bitstreamFilter: bsf),
                                  onOutTime: onOutTime)
                }
            }
            guard FileManager.default.fileExists(atPath: piece.path) else {
                throw ExportError.missingSegment
            }
            pieces.append(piece)
            onProgress(ExportProgress.withinClip(
                segmentFrames: segmentFrames, completedSegments: s + 1, currentRunFraction: 0))
        }

        let result: URL
        if pieces.count == 1 {
            result = pieces[0]
        } else {
            let joined = work.appendingPathComponent("c\(clipIndex)_joined.\(ext)")
            let listFile = work.appendingPathComponent("c\(clipIndex)_concat.txt")
            try ExportEngine.concatListContents(pieces: pieces, durations: segmentSpans(plan, index: index))
                .write(to: listFile, atomically: true, encoding: .utf8)
            try await run(ffmpeg, ExportEngine.concatArguments(listFile: listFile, output: joined))
            result = joined
        }
        try await verifyPiece(ffmpeg, result, expectedFrames: expectedFrameCount(plan),
                              plan: plan, sourcePts: index.pts)
        return result
    }

    /// The video frame count a produced piece must have: the planned segments tile the kept
    /// presentation range contiguously, so it is their combined length. `verifyPiece` checks
    /// the real output against this (ADR-0008 verifies by frame count, never by reading the
    /// reset output timestamps).
    static func expectedFrameCount(_ plan: [PlannedSegment]) -> Int {
        plan.reduce(0) { $0 + $1.range.count }
    }

    /// The timeline span (seconds) each planned segment should occupy when its pieces are
    /// concatenated — the `duration` directive fed to `ExportEngine.concatListContents` to
    /// close the start_time seam gap. A segment `[lo, hi)` spans from its first kept frame to
    /// the *next* segment's first frame, i.e. `pts[hi] - pts[lo]`: an exact presentation-time
    /// offset (no frame-rate estimate, so the demuxer can't truncate the piece). The segments
    /// tile contiguously, so for every segment but the last `hi` is the next segment's start —
    /// a real, in-bounds frame index. The final segment may run to the clip end (`hi ==
    /// count`, where `pts[hi]` would be out of bounds); its span never offsets anything, so it
    /// is left `nil` (no directive). Returns one entry per segment, aligned to the pieces.
    static func segmentSpans(_ plan: [PlannedSegment], index: FrameIndex) -> [Double?] {
        plan.map { seg in
            let lo = seg.range.lowerBound, hi = seg.range.upperBound
            guard lo < index.pts.count, hi < index.pts.count else { return nil }
            return index.pts[hi] - index.pts[lo]
        }
    }

    /// Verifies a produced video piece before it ships (ADR-0008). Three checks, any of
    /// which throws rather than letting a silently-wrong cut through:
    ///   1. Frame count — the output's video packet count must equal the planned total,
    ///      catching any frame leaking past a cut (a desynced index once made a 2-clip
    ///      export come out +10 frames).
    ///   2. Decode check — a full `-xerror` decode pass must succeed, catching a corrupt
    ///      re-encode→copy seam (e.g. orphaned leading pictures) that a frame count alone
    ///      would miss.
    ///   3. Timestamp check — the output's presentation timestamps must be free of the seam
    ///      gap (start_time concat offset) and duplicates (B-pyramid/MKV collapse) that the
    ///      frame count and decode would both pass over. Re-encoded spans, seams, and
    ///      segment-edge windows are held to uniform spacing; a copied span is held to the
    ///      *source's* timestamp pattern instead — a faithful copy of an irregular source
    ///      is correct output, not a defect (issue #19, plan-aware
    ///      `ExportEngine.timestampDefect`).
    private static func verifyPiece(_ ffmpeg: URL, _ piece: URL, expectedFrames: Int,
                                    plan: [PlannedSegment], sourcePts: [Double]) async throws {
        let actual = try await FrameIndexer.frameCount(url: piece)
        guard actual == expectedFrames else {
            throw ExportError.verificationFailed(
                "Produced \(actual) video frames but the cut kept \(expectedFrames).")
        }
        let decode = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", piece.path, "-f", "null", "-"])
        guard decode.status == 0 else {
            let detail = String(data: decode.stderr, encoding: .utf8).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "decode exited \(decode.status)"
            throw ExportError.verificationFailed("A decode check failed on the cut.\n\(detail)")
        }
        let pts = try await FrameIndexer.buildIndex(url: piece).pts
        if let reason = ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: sourcePts) {
            throw ExportError.verificationFailed("The cut produced irregular timestamps: \(reason)")
        }
    }

    /// The clip's mean frame interval in seconds — exact under CFR; a timestamp-dirty
    /// source's stray dup/gap anomalies (issue #19) wash out over the average. Only
    /// feeds progress estimation. `nil` below two frames.
    private static func meanFrameInterval(_ index: FrameIndex) -> Double? {
        let pts = index.pts
        guard pts.count >= 2 else { return nil }
        return (pts[pts.count - 1] - pts[0]) / Double(pts.count - 1)
    }

    /// Runs ffmpeg and turns a non-zero exit into a `cutFailed` with its stderr. With
    /// `onOutTime` the run also streams `-progress pipe:1` (issue #9), reporting each
    /// block's out_time seconds as it arrives.
    private static func run(_ ffmpeg: URL, _ args: [String],
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
            throw ExportError.cutFailed(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
    }
}
