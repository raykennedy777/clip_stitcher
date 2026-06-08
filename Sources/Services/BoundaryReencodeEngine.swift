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
        switch codec {
        case "hevc":
            var args = ["-c:v", "libx265", "-pix_fmt", pixFmt]
            if let p = encoderProfile(profile, codec: "hevc") { args += ["-profile:v", p] }
            return args
        case "mpeg2video":
            var args = ["-c:v", "mpeg2video", "-pix_fmt", pixFmt]
            if let p = encoderProfile(profile, codec: "mpeg2video") { args += ["-profile:v", p] }
            switch fieldOrder {
            case "tt", "tb": args += ["-flags", "+ildct+ilme", "-top", "1"]
            case "bb", "bt": args += ["-flags", "+ildct+ilme", "-top", "0"]
            default: break   // progressive / unknown — no interlace flags
            }
            return args
        default:   // h264 and anything else -> libx264
            var args = ["-c:v", "libx264", "-pix_fmt", pixFmt]
            if let p = encoderProfile(profile, codec: "h264") { args += ["-profile:v", p] }
            return args
        }
    }

    /// Maps an ffprobe `profile` string to the `-profile:v` token its re-encode encoder
    /// expects, for the profiles seen in this domain (broadcast/sports H.264, HEVC, and
    /// MPEG-2). Returns `nil` for an unrecognised profile — the caller then omits
    /// `-profile:v` and lets the encoder infer one from the pixel format, which matches
    /// the source for every common case (verified). Never guesses: a wrong token would
    /// abort the encode.
    static func encoderProfile(_ profile: String?, codec: String) -> String? {
        guard let profile else { return nil }
        switch codec {
        case "h264":
            return [
                "Constrained Baseline": "baseline", "Baseline": "baseline", "Main": "main",
                "High": "high", "High 10": "high10", "High 4:2:2": "high422",
                "High 4:4:4 Predictive": "high444",
            ][profile]
        case "hevc":
            return [
                "Main": "main", "Main 10": "main10", "Main 12": "main12",
                "Main Still Picture": "mainstillpicture",
            ][profile]
        case "mpeg2video":
            return [
                "Simple": "simple", "Main": "main", "High": "high", "4:2:2": "422",
            ][profile]
        default:
            return nil
        }
    }

    /// ffmpeg args to re-encode the partial-GOP presentation range `[range.lowerBound,
    /// range.upperBound)` into `output`. To avoid decoding the whole file, it input-seeks
    /// to the keyframe at/before the range start (which the decoder emits as `n = 0`),
    /// then selects frames RELATIVE to that keyframe. The seek is start_time-relative
    /// (ffmpeg subtracts the stream start_time from `-ss`), so the first presentation PTS
    /// is removed. Audio is dropped here; the rebuilt track is muxed in later.
    static func reencodeSegmentArguments(
        source: URL, range: Range<Int>, index: FrameIndex, encoder: [String], output: URL
    ) -> [String] {
        let anchor = index.keyframeIndex(atOrBefore: range.lowerBound)
        let startOffset = index.pts.first ?? 0
        let seek = index.pts[anchor] - startOffset
        let relStart = range.lowerBound - anchor
        let relEnd = range.upperBound - 1 - anchor
        var args = ["-v", "error", "-ss", ExportEngine.timeString(seek), "-i", source.path]
        args += ["-vf", "select='between(n\\,\(relStart)\\,\(relEnd))',setpts=PTS-STARTPTS"]
        args += encoder
        args += ["-an", output.path]
        return args
    }

    /// Maps a copy segment `[copyRange.lowerBound, copyRange.upperBound)` onto a
    /// `SegmentPlan` so its validated segment-muxer cut/remux can stream-copy the span
    /// bit-exact. A bound that is a clip boundary (frame 0 / the last frame) gets no cut
    /// at that end — copy from the file start / to the file end — and a span touching
    /// neither boundary becomes a two-cut plan whose wanted piece is the middle. The cut
    /// times are start_time-corrected DTS midpoints (ADR-0008).
    static func copySegmentPlan(copyRange: Range<Int>, index: FrameIndex) -> SegmentPlan {
        let needsInCut = copyRange.lowerBound > 0
        let needsOutCut = copyRange.upperBound < index.count
        return SegmentPlan(
            inFrame: copyRange.lowerBound,
            outFrame: copyRange.upperBound,
            inSegmentTime: needsInCut ? index.segmentTime(forCutAt: copyRange.lowerBound) : nil,
            outSegmentTime: needsOutCut ? index.segmentTime(forCutAt: copyRange.upperBound) : nil
        )
    }

    // MARK: - Orchestration

    /// Executes a Milestone 2 plan for one clip into a single **video** piece in `work`
    /// and returns it. Each re-encode segment is a frame-selected encode; each copy
    /// segment is M1's segment-muxer cut/remux; the pieces are concatenated in plan order
    /// (a single-segment plan needs no concat). Audio is rebuilt separately, as in M1.
    static func produceVideoPiece(
        _ ffmpeg: URL, source: URL, plan: [PlannedSegment], index: FrameIndex,
        encoder: [String], work: URL, ext: String, clipIndex: Int
    ) async throws -> URL {
        guard !plan.isEmpty else { throw ExportError.invalidPlan }

        var pieces: [URL] = []
        for (s, segment) in plan.enumerated() {
            let piece: URL
            switch segment.kind {
            case .reEncode:
                piece = work.appendingPathComponent("c\(clipIndex)_s\(s)_re.\(ext)")
                try await run(ffmpeg, reencodeSegmentArguments(
                    source: source, range: segment.range, index: index,
                    encoder: encoder, output: piece))
            case .copy:
                let copyPlan = copySegmentPlan(copyRange: segment.range, index: index)
                if ExportEngine.needsCut(copyPlan) {
                    let pattern = work.appendingPathComponent("c\(clipIndex)_s\(s)_cp_%03d.\(ext)").path
                    try await run(ffmpeg, ExportEngine.cutArguments(
                        source: source, plan: copyPlan, segmentPattern: pattern))
                    piece = work.appendingPathComponent(String(
                        format: "c\(clipIndex)_s\(s)_cp_%03d.\(ext)",
                        ExportEngine.wantedSegmentIndex(plan: copyPlan)))
                } else {
                    piece = work.appendingPathComponent("c\(clipIndex)_s\(s)_cp.\(ext)")
                    try await run(ffmpeg, ExportEngine.remuxArguments(source: source, output: piece))
                }
            }
            guard FileManager.default.fileExists(atPath: piece.path) else {
                throw ExportError.missingSegment
            }
            pieces.append(piece)
        }

        let result: URL
        if pieces.count == 1 {
            result = pieces[0]
        } else {
            let joined = work.appendingPathComponent("c\(clipIndex)_joined.\(ext)")
            let listFile = work.appendingPathComponent("c\(clipIndex)_concat.txt")
            try ExportEngine.concatListContents(pieces: pieces).write(to: listFile, atomically: true, encoding: .utf8)
            try await run(ffmpeg, ExportEngine.concatArguments(listFile: listFile, output: joined))
            result = joined
        }
        try await verifyPiece(ffmpeg, result, expectedFrames: expectedFrameCount(plan))
        return result
    }

    /// The video frame count a produced piece must have: the planned segments tile the kept
    /// presentation range contiguously, so it is their combined length. `verifyPiece` checks
    /// the real output against this (ADR-0008 verifies by frame count, never by reading the
    /// reset output timestamps).
    static func expectedFrameCount(_ plan: [PlannedSegment]) -> Int {
        plan.reduce(0) { $0 + $1.range.count }
    }

    /// Verifies a produced video piece before it ships (ADR-0008). Two checks, either of
    /// which throws rather than letting a silently-wrong cut through:
    ///   1. Frame count — the output's video packet count must equal the planned total,
    ///      catching any frame leaking past a cut (a desynced index once made a 2-clip
    ///      export come out +10 frames).
    ///   2. Decode check — a full `-xerror` decode pass must succeed, catching a corrupt
    ///      re-encode→copy seam (e.g. orphaned leading pictures) that a frame count alone
    ///      would miss.
    private static func verifyPiece(_ ffmpeg: URL, _ piece: URL, expectedFrames: Int) async throws {
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
    }

    /// Runs ffmpeg and turns a non-zero exit into a `cutFailed` with its stderr.
    private static func run(_ ffmpeg: URL, _ args: [String]) async throws {
        let result = try await ProcessRunner.run(ffmpeg, args)
        guard result.status == 0 else {
            throw ExportError.cutFailed(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
    }
}
