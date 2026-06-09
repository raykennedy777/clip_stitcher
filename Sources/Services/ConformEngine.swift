import Foundation

/// Milestone 3 conform executor (ADR-0011): fully re-encodes a non-matching clip's kept
/// range so that, re-imported, it matches the target clip on every `MatchEvaluator`
/// dimension. The argument builders are pure so the exact command shape can be unit-tested;
/// the recipes were validated against the real H.264/HEVC/MPEG-2 footage in the shell.
enum ConformEngine {
    /// The probed video specs a conformed clip is transformed between: its own source spec and
    /// the target clip's. Carried on an `ExportItem` to mark it for conform (ADR-0011).
    struct VideoConform: Equatable {
        var sourceVideo: VideoProperties
        var targetVideo: VideoProperties
    }

    /// ffmpeg video filter-chain + encoder args that transform `source` → `target`. The
    /// chain runs deinterlace (if any) → scale → pad (only on a display-aspect mismatch) →
    /// setsar → format → fps/interlace; the encoder then pins the target codec, profile,
    /// level, interlace flags, and color range.
    static func conformVideoArgs(source: VideoProperties, target: VideoProperties) -> [String] {
        let chain = filterChain(source: source, target: target).joined(separator: ",")
        return ["-vf", chain] + encoderArgs(target: target)
    }

    /// The audio filter that conforms a clip's audio to the target's sample rate and channel
    /// layout before the sample-level concat (ADR-0011). Applied per conforming leg in the
    /// audio rebuild; matching clips need no filter. Idempotent when already on target.
    static func audioFilter(sampleRate: Int, channels: Int) -> String {
        "aresample=\(sampleRate),aformat=channel_layouts=\(channelLayout(channels))"
    }

    /// ffmpeg channel-layout name for a channel count (the broadcast cases). An uncommon
    /// count falls back to stereo — rate/channels are match dimensions referenced from the
    /// target, and the footage in this domain is mono/stereo.
    static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "stereo"
        }
    }

    /// Full ffmpeg args to conform one clip's kept range into `output`: a fast seek to the
    /// in-point time and a read duration (the same time window the audio uses), then the
    /// source→target transform. Audio is dropped; the rebuilt track is muxed in later. An
    /// open start/end omits the corresponding seek flag (read from file start / to file end).
    static func conformArguments(
        source: URL, start: Double?, end: Double?,
        sourceVideo: VideoProperties, targetVideo: VideoProperties, output: URL
    ) -> [String] {
        var args = ["-v", "error"]
        if let start { args += ["-ss", ExportEngine.timeString(start)] }
        if let end { args += ["-t", ExportEngine.timeString(end - (start ?? 0))] }
        args += ["-i", source.path]
        args += conformVideoArgs(source: sourceVideo, target: targetVideo)
        args += ["-an", output.path]
        return args
    }

    // MARK: - Orchestration

    /// Conforms one clip's kept range into a single video piece in `work` and returns it. The
    /// piece is a from-scratch re-encode to the target spec (`conformArguments`), then it
    /// **self-verifies before it ships** (ADR-0011): re-probed it must match the target's
    /// video spec, and a full `-xerror` decode must pass — otherwise the export fails loudly
    /// naming the offending dimension, never shipping a near-miss. Audio is rebuilt separately.
    static func produceConformedPiece(
        _ ffmpeg: URL, source: URL, conform: VideoConform,
        start: Double?, end: Double?, work: URL, ext: String, clipIndex: Int
    ) async throws -> URL {
        let piece = work.appendingPathComponent("c\(clipIndex)_conform.\(ext)")
        let args = conformArguments(source: source, start: start, end: end,
                                    sourceVideo: conform.sourceVideo, targetVideo: conform.targetVideo,
                                    output: piece)
        let result = try await ProcessRunner.run(ffmpeg, args)
        guard result.status == 0 else {
            throw ExportError.conformFailed(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
        guard FileManager.default.fileExists(atPath: piece.path) else { throw ExportError.missingSegment }
        let expected = try await expectedFrames(
            ffmpeg, source: source, start: start, end: end, target: conform.targetVideo)
        try await verifyConformed(ffmpeg, piece, target: conform.targetVideo, expectedFrames: expected)
        return piece
    }

    /// The frame count a conformed piece should have: the kept window duration × the target
    /// frame rate. An open end reads to the source's end, so its duration is probed; the
    /// window is `(end ?? sourceDuration) - (start ?? 0)`. Returns `nil` when the duration
    /// can't be determined, so `verifyConformed` skips the count check rather than fail blind.
    private static func expectedFrames(
        _ ffmpeg: URL, source: URL, start: Double?, end: Double?, target: VideoProperties
    ) async throws -> Int? {
        let windowEnd: Double
        if let end {
            windowEnd = end
        } else if let dur = try await MediaProbe.probe(url: source).duration {
            windowEnd = dur
        } else {
            return nil
        }
        return expectedFrameCount(windowDuration: windowEnd - (start ?? 0),
                                  targetFrameRate: target.frameRate)
    }

    /// The frame count a conformed piece should have for a kept window of `windowDuration`
    /// seconds re-encoded to `targetFrameRate`: `duration × fps`, rounded. M2's exact
    /// frame-count assertion is relaxed to this (±1) for conformed pieces because fps
    /// conversion legitimately changes the count (ADR-0011). `nil` when the rate is unparseable.
    static func expectedFrameCount(windowDuration: Double, targetFrameRate: String) -> Int? {
        guard windowDuration > 0, let fps = frameRateValue(targetFrameRate) else { return nil }
        return Int((windowDuration * fps).rounded())
    }

    /// Verifies a conformed piece against the acceptance bar (ADR-0011): its re-probed video
    /// must match the target spec, its frame count must be within ±1 of the kept window at the
    /// target rate (the relaxed M2 assertion), and a full decode must succeed.
    private static func verifyConformed(
        _ ffmpeg: URL, _ piece: URL, target: VideoProperties, expectedFrames: Int?
    ) async throws {
        let probed = try await MediaProbe.probe(url: piece).video
        guard let v = probed, MatchEvaluator.videoMatches(v, target) else {
            throw ExportError.verificationFailed(
                "The conformed clip did not reach the target spec (\(mismatchSummary(probed, target))).")
        }
        if let expected = expectedFrames {
            let actual = try await FrameIndexer.frameCount(url: piece)
            guard abs(actual - expected) <= 1 else {
                throw ExportError.verificationFailed(
                    "The conformed clip has \(actual) frames but the kept range at the target rate is ~\(expected) (±1).")
            }
        }
        let decode = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", piece.path, "-f", "null", "-"])
        guard decode.status == 0 else {
            let detail = String(data: decode.stderr, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
                ?? "decode exited \(decode.status)"
            throw ExportError.verificationFailed("A decode check failed on the conformed clip.\n\(detail)")
        }
    }

    /// Names the dimensions a conformed output missed, for a useful failure message.
    private static func mismatchSummary(_ got: VideoProperties?, _ want: VideoProperties) -> String {
        guard let g = got else { return "no video stream" }
        var diffs: [String] = []
        if g.codec != want.codec { diffs.append("codec \(g.codec)≠\(want.codec)") }
        if g.profile != want.profile { diffs.append("profile \(g.profile ?? "?")≠\(want.profile ?? "?")") }
        if g.level != want.level { diffs.append("level \(g.level ?? "?")≠\(want.level ?? "?")") }
        if g.width != want.width || g.height != want.height {
            diffs.append("size \(g.width)x\(g.height)≠\(want.width)x\(want.height)")
        }
        if g.frameRate != want.frameRate { diffs.append("fps \(g.frameRate)≠\(want.frameRate)") }
        if g.pixelFormat != want.pixelFormat { diffs.append("pixfmt \(g.pixelFormat)≠\(want.pixelFormat)") }
        if MatchEvaluator.normalizedFieldOrder(g.fieldOrder) != MatchEvaluator.normalizedFieldOrder(want.fieldOrder) {
            diffs.append("field \(g.fieldOrder ?? "?")≠\(want.fieldOrder ?? "?")")
        }
        if g.sampleAspectRatio != want.sampleAspectRatio {
            diffs.append("sar \(g.sampleAspectRatio ?? "?")≠\(want.sampleAspectRatio ?? "?")")
        }
        if g.colorPrimaries != want.colorPrimaries || g.colorTransfer != want.colorTransfer || g.colorRange != want.colorRange {
            diffs.append("color")
        }
        return diffs.isEmpty ? "video stream differs" : diffs.joined(separator: ", ")
    }

    // MARK: - Filter chain

    private static func filterChain(source: VideoProperties, target: VideoProperties) -> [String] {
        let srcInterlaced = isInterlaced(source.fieldOrder)
        let tgtInterlaced = isInterlaced(target.fieldOrder)
        var filters: [String] = []

        // Deinterlace first, so scaling and re-encoding work on whole progressive frames.
        if srcInterlaced && !tgtInterlaced { filters.append("bwdif=mode=0") }

        // Scale to the target frame, padding only when the display aspect ratios differ —
        // a naive scale=W:H would stretch a clip of a different shape (ADR-0011).
        filters += scaleAndPad(source: source, target: target)
        filters.append("setsar=\(sarFraction(target.sampleAspectRatio))")
        filters.append("format=\(target.pixelFormat)")
        // TODO(color): no colorspace/primaries/transfer conversion is emitted — only the encoder's
        // -color_range is pinned. The real footage all probes primaries/transfer = None, so a target
        // that sets them is caught by verifyConformed's loud fail (mismatchSummary "color") rather than
        // converted. True color-aware conversion (zscale) is deferred per ADR-0011.

        // Frame-rate / scan tail. Interlacing a progressive source needs the field-rate
        // (2× the target frame rate) feeding the interlace filter, which halves it back.
        if tgtInterlaced && !srcInterlaced {
            filters.append("fps=\(fpsToken(target.frameRate, double: true))")
            filters.append("interlace=scan=\(topFieldFirst(target.fieldOrder) ? "tff" : "bff")")
        } else {
            filters.append("fps=\(fpsToken(target.frameRate, double: false))")
        }
        return filters
    }

    /// The scale (and, on a DAR mismatch, pad) filters. When source and target display the
    /// same aspect, a plain scale-fill suffices. Otherwise the content is scaled to fit the
    /// target frame at its own aspect and centred with black bars (letterbox/pillarbox).
    /// Dimensions are computed in display space — `force_original_aspect_ratio` works on
    /// storage pixels and would mis-fit an anamorphic source (verified in the shell).
    private static func scaleAndPad(source: VideoProperties, target: VideoProperties) -> [String] {
        let w = target.width, h = target.height
        if displayAspectsMatch(source: source, target: target) {
            return ["scale=\(w):\(h)"]
        }
        let (cw, ch) = fittedContentSize(source: source, target: target)
        let x = (w - cw) / 2, y = (h - ch) / 2
        return ["scale=\(cw):\(ch)", "pad=\(w):\(h):\(x):\(y)"]
    }

    /// Content size (even storage dimensions) that fits the source's display aspect inside the
    /// target frame, leaving room for letterbox/pillarbox bars. Computed in display space then
    /// converted back through the target SAR.
    private static func fittedContentSize(source: VideoProperties, target: VideoProperties) -> (Int, Int) {
        let srcDAR = displayAspect(source)
        let sarf = sarValue(target.sampleAspectRatio)
        let tgtDAR = (Double(target.width) * sarf) / Double(target.height)
        let displayW: Double, displayH: Double
        if srcDAR >= tgtDAR {            // source wider → letterbox (bars top/bottom)
            displayW = Double(target.width) * sarf
            displayH = displayW / srcDAR
        } else {                          // source narrower → pillarbox (bars left/right)
            displayH = Double(target.height)
            displayW = displayH * srcDAR
        }
        return (evenRound(displayW / sarf), evenRound(displayH))
    }

    // MARK: - Encoder

    // TODO(consolidate): the codec switch, profile mapping (via BoundaryReencodeEngine.encoderProfile),
    // and level tokens here mirror BoundaryReencodeEngine.reencodeVideoArgs (ADR-0011 consequences).
    // Conform additionally pins level + color range; M2 carries them through by copy. Fold the shared
    // encoder/profile/level selection into one place in a later refactor rather than letting the two drift.
    private static func encoderArgs(target: VideoProperties) -> [String] {
        var args: [String]
        switch target.codec {
        case "hevc":
            args = ["-c:v", "libx265", "-profile:v", profile(target),
                    "-x265-params", x265Params(target)]
        case "mpeg2video":
            args = ["-c:v", "mpeg2video", "-profile:v", profile(target)]
            if isInterlaced(target.fieldOrder) {
                args += ["-flags", "+ildct+ilme", "-top", topFieldFirst(target.fieldOrder) ? "1" : "0"]
            }
        default:   // h264
            args = ["-c:v", "libx264", "-profile:v", profile(target)]
            if let lvl = h264Level(target.level) { args += ["-level", lvl] }
        }
        // Drop an unmapped profile rather than guess (a wrong token aborts the encode).
        if args.count >= 4, args[2] == "-profile:v", args[3].isEmpty {
            args.removeSubrange(2...3)
        }
        if let range = target.colorRange { args += ["-color_range", range] }
        return args
    }

    private static func profile(_ target: VideoProperties) -> String {
        BoundaryReencodeEngine.encoderProfile(target.profile, codec: target.codec) ?? ""
    }

    /// libx265 params: quiet logging plus the target's level as `level-idc` (HEVC's probed
    /// `level` is `general_level_idc` = level × 30, e.g. 123 → 4.1).
    private static func x265Params(_ target: VideoProperties) -> String {
        var p = "log-level=error"
        if let n = target.level.flatMap(Int.init) {
            p += ":level-idc=\(n / 30).\((n % 30) / 3)"
        }
        return p
    }

    /// libx264 `-level` token from the probed integer level (e.g. 40 → "4.0", 41 → "4.1").
    private static func h264Level(_ level: String?) -> String? {
        guard let n = level.flatMap(Int.init) else { return nil }
        return "\(n / 10).\(n % 10)"
    }

    // MARK: - Field order / aspect / rate helpers

    private static func isInterlaced(_ field: String?) -> Bool {
        ["tt", "bb", "tb", "bt"].contains(MatchEvaluator.normalizedFieldOrder(field))
    }

    private static func topFieldFirst(_ field: String?) -> Bool {
        let f = MatchEvaluator.normalizedFieldOrder(field)
        return f == "tt" || f == "tb"
    }

    private static func displayAspectsMatch(source: VideoProperties, target: VideoProperties) -> Bool {
        abs(displayAspect(source) - displayAspect(target)) < 0.01
    }

    private static func displayAspect(_ v: VideoProperties) -> Double {
        (Double(v.width) / Double(v.height)) * sarValue(v.sampleAspectRatio)
    }

    /// Parses an ffprobe SAR ("64:45", "1:1") to a Double; missing/degenerate values are 1.
    private static func sarValue(_ sar: String?) -> Double {
        let p = (sar ?? "1:1").split(separator: ":").compactMap { Double($0) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { return 1 }
        return p[0] / p[1]
    }

    /// SAR as a `num/den` token for `setsar` (missing/degenerate → "1/1").
    private static func sarFraction(_ sar: String?) -> String {
        let p = (sar ?? "1:1").split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { return "1/1" }
        return "\(p[0])/\(p[1])"
    }

    /// Frame-rate filter token from an ffprobe "num/den" rate, optionally doubled for the
    /// field rate. A unit denominator collapses to the integer ("25/1" → "25", doubled "50").
    private static func fpsToken(_ rate: String, double: Bool) -> String {
        let p = rate.split(separator: "/").compactMap { Int($0) }
        guard p.count == 2, p[1] != 0 else { return double ? "50" : "25" }
        let num = double ? p[0] * 2 : p[0]
        return p[1] == 1 ? "\(num)" : "\(num)/\(p[1])"
    }

    /// Frames-per-second as a Double from an ffprobe "num/den" rate ("25/1" → 25.0, "30000/1001"
    /// → 29.97). `nil` for an unparseable/degenerate rate.
    private static func frameRateValue(_ rate: String) -> Double? {
        let p = rate.split(separator: "/").compactMap { Double($0) }
        guard p.count == 2, p[1] != 0 else { return nil }
        return p[0] / p[1]
    }

    private static func evenRound(_ x: Double) -> Int {
        let n = Int(x.rounded())
        return n % 2 == 0 ? n : n + 1
    }
}
