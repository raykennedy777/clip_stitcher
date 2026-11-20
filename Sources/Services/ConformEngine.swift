import Foundation

enum ConformEngine {
    struct VideoConform: Equatable {
        var sourceVideo: VideoProperties
        var targetVideo: VideoProperties
        var damage: [DamageZone] = []
        var trimEnd: Double? = nil
        var crf: Int? = nil
    }

    static func conformVideoArgs(source: VideoProperties, target: VideoProperties,
                                 damage: [DamageZone] = [], windowStart: Double? = nil,
                                 windowEnd: Double? = nil, crf: Int? = nil,
                                 reorderDepth: Int = 1) -> [String] {
        let chain = filterChain(source: source, target: target,
                                repair: repairSelect(damage: damage, windowStart: windowStart,
                                                     windowEnd: windowEnd,
                                                     sourceFrameRate: source.frameRate))
            .joined(separator: ",")
        return ["-vf", chain] + encoderArgs(target: target, crf: crf, reorderDepth: reorderDepth)
    }

    static func repairSelect(damage: [DamageZone], windowStart: Double?, windowEnd: Double?,
                             sourceFrameRate: String) -> String? {
        let start = windowStart ?? 0
        let interval = 1 / (frameRateValue(sourceFrameRate) ?? 25)
        let quarter = interval / 4
        let terms = damage
            .filter { zone in
                zone.affectsVideo && zone.end > start
                    && (windowEnd.map { zone.start < $0 } ?? true)
            }
            .map { zone in
                let from = max(zone.start - quarter, start + interval - quarter) - start
                let to = zone.end + quarter - start
                return "not(between(t\\,\(ExportEngine.timeString(from))\\,\(ExportEngine.timeString(to))))"
            }
        return terms.isEmpty ? nil : "select='\(terms.joined(separator: "*"))'"
    }

    static func audioFilter(sampleRate: Int, channels: Int, fillGaps: Bool = false) -> String {
        let resample = fillGaps ? "aresample=\(sampleRate):async=1:first_pts=0"
                                : "aresample=\(sampleRate)"
        return resample + ",aformat=channel_layouts=\(channelLayout(channels))"
    }

    static func mixFilter(_ mix: ChannelMix, sourceChannels: Int?) -> String? {
        guard !mix.isNoOp(sourceChannels: sourceChannels) else { return nil }
        let foldDown = "aformat=channel_layouts=stereo"
        let fold = (sourceChannels ?? 0) > 2 ? foldDown + "," : ""
        switch mix {
        case .original:
            return nil
        case .stereo:
            return foldDown
        case .leftOnly:
            return fold + "pan=stereo|c0=c0|c1=c0"
        case .rightOnly:
            return fold + "pan=stereo|c0=c1|c1=c1"
        case .mono:
            return fold + "pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1"
        }
    }

    static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "stereo"
        }
    }

    static func conformArguments(
        source: URL, start: Double?, end: Double?,
        sourceVideo: VideoProperties, targetVideo: VideoProperties, output: URL,
        trackTimescale: Int? = nil, damage: [DamageZone] = [], crf: Int? = nil,
        reorderDepth: Int = 1
    ) -> [String] {
        var args = ["-v", "error"]
        if let start { args += ["-ss", ExportEngine.timeString(start)] }
        if let end { args += ["-t", ExportEngine.timeString(end - (start ?? 0))] }
        args += ["-i", source.path]
        args += conformVideoArgs(source: sourceVideo, target: targetVideo,
                                 damage: damage, windowStart: start, windowEnd: end, crf: crf,
                                 reorderDepth: reorderDepth)
        args += ["-bsf:v", ExportEngine.parameterSetRepeatFilter]
        if let trackTimescale { args += ["-video_track_timescale", String(trackTimescale)] }
        args += ["-an", output.path]
        return args
    }

    static func produceConformedPiece(
        _ ffmpeg: URL, source: URL, conform: VideoConform,
        start: Double?, end: Double?, work: URL, ext: String, clipIndex: Int,
        displayName: String = "", trackTimescale: Int? = nil, reorderDepth: Int = 1,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
        log: (String) -> Void = { _ in },
        pieceCache: PieceCache? = nil
    ) async throws -> URL {
        let piece = work.appendingPathComponent("c\(clipIndex)_conform.\(ext)")
        let windowEnd: Double?
        if let end {
            windowEnd = end
        } else {
            windowEnd = try await MediaProbe.probe(url: source).duration
        }
        let trimEnd = conform.trimEnd
        let effectiveEnd = trimEnd ?? end
        let windowDuration = (trimEnd ?? windowEnd).map { $0 - (start ?? 0) }
        let args = conformArguments(source: source, start: start, end: effectiveEnd,
                                    sourceVideo: conform.sourceVideo, targetVideo: conform.targetVideo,
                                    output: piece,
                                    trackTimescale: ext.lowercased() == "mp4" ? trackTimescale : nil,
                                    damage: conform.damage, crf: conform.crf,
                                    reorderDepth: reorderDepth)
        let encodeClock = StageClock()
        let cacheKey = await pieceCache?.key(source: source, arguments: args, output: piece,
                                             segment: nil, ffmpeg: ffmpeg)
        let cached = pieceCache.map { cache in cacheKey.map { cache.fetch($0, to: piece) } ?? false } ?? false
        if !cached {
            let parser = ProgressParser()
            let result = try await ProcessRunner.run(ffmpeg, ExportProgress.progressArguments(args)) { chunk in
                if let t = parser.feed(chunk) {
                    onProgress(ExportProgress.runFraction(outTime: t, expectedSeconds: windowDuration))
                }
            }
            guard result.status == 0 else {
                throw ExportError.conformFailed(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
            }
        }
        guard FileManager.default.fileExists(atPath: piece.path) else { throw ExportError.missingSegment }
        let expected = windowDuration.flatMap {
            expectedFrameCount(windowDuration: $0, targetFrameRate: conform.targetVideo.frameRate)
        }
        log(conformTimingLine(clipIndex: clipIndex, frames: expected, seconds: encodeClock.seconds,
                              cached: cached))
        let verifyClock = StageClock()
        do {
            try await verifyConformed(ffmpeg, piece, target: conform.targetVideo, expectedFrames: expected,
                                      shortfallAllowance: eofShortfallAllowance(
                                          trimEnd: trimEnd, fileEnd: windowEnd,
                                          targetFrameRate: conform.targetVideo.frameRate),
                                      requireSilentDecode: conform.damage.isEmpty,
                                      at: VerificationLocation(
                                          clipIndex: clipIndex, displayName: displayName,
                                          piece: piece.lastPathComponent, conformed: true))
        } catch {
            if cached, let pieceCache, let cacheKey { pieceCache.evict(cacheKey, ext: ext) }
            throw error
        }
        log("clip \(clipIndex) verify: \(verifyClock.label)")
        if !cached, let pieceCache, let cacheKey { pieceCache.store(cacheKey, from: piece) }
        return piece
    }

    static func conformTimingLine(clipIndex: Int, frames: Int?, seconds: Double,
                                  cached: Bool = false) -> String {
        var line = "clip \(clipIndex) conform: \(StageClock.label(seconds))"
        if let frames {
            line += ", \(StageClock.count(frames, "frame"))"
            if !cached, let fps = StageClock.fpsLabel(frames: frames, seconds: seconds) { line += ", \(fps)" }
        }
        if cached { line += ", piece cache hit" }
        return line
    }

    static func expectedFrameCount(windowDuration: Double, targetFrameRate: String) -> Int? {
        guard windowDuration > 0, let fps = frameRateValue(targetFrameRate) else { return nil }
        return Int((windowDuration * fps).rounded())
    }

    static func eofShortfallAllowance(trimEnd: Double?, fileEnd: Double?,
                                      targetFrameRate: String) -> Int {
        guard let trimEnd, let fileEnd, let fps = frameRateValue(targetFrameRate) else { return 0 }
        return max(0, Int(((fileEnd - trimEnd) * fps).rounded()) + 1)
    }

    // ADR-0011, ADR-0032
    private static func verifyConformed(
        _ ffmpeg: URL, _ piece: URL, target: VideoProperties, expectedFrames: Int?,
        shortfallAllowance: Int = 0, requireSilentDecode: Bool = true,
        at location: VerificationLocation
    ) async throws {
        var probed = try await MediaProbe.probe(url: piece).video
        if let measured = await MediaProbe.codedFieldOrder(url: piece) {
            probed?.fieldOrder = measured
        }
        guard let v = probed, MatchEvaluator.conformedVideoMatches(v, target) else {
            throw ExportError.verificationFailed(location.message(
                "The conformed clip did not reach the target spec (\(mismatchSummary(probed, target)))."))
        }
        if let expected = expectedFrames {
            let actual = try await FrameIndexer.frameCount(url: piece)
            guard actual <= expected + 1, actual >= expected - 1 - shortfallAllowance else {
                throw ExportError.verificationFailed(location.message(
                    "The conformed clip has \(actual) frames but the kept range at the target rate is ~\(expected) (±1"
                    + (shortfallAllowance > 0 ? ", −\(shortfallAllowance) allowed at the damaged file end" : "")
                    + ")."))
            }
        }
        let decode = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", piece.path, "-f", "null", "-"])
        let complaints = String(data: decode.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard decode.status == 0 else {
            throw ExportError.verificationFailed(location.message(
                "A decode check failed on the conformed clip.",
                detail: complaints.isEmpty ? "decode exited \(decode.status)" : complaints))
        }
        guard !requireSilentDecode || complaints.isEmpty else {
            throw ExportError.verificationFailed(location.message(
                "A decode check failed on the conformed clip.", detail: complaints))
        }
        let pts = try await FrameIndexer.buildIndex(url: piece).pts
        if let reason = ExportEngine.timestampDefect(pts: pts) {
            throw ExportError.verificationFailed(location.message(
                "The conformed clip has irregular timestamps: \(reason)"))
        }
    }

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
        if MatchEvaluator.scanDirection(g.fieldOrder) != MatchEvaluator.scanDirection(want.fieldOrder) {
            diffs.append("scan \(g.fieldOrder ?? "?")≠\(want.fieldOrder ?? "?")")
        }
        if g.sampleAspectRatio != want.sampleAspectRatio {
            diffs.append("sar \(g.sampleAspectRatio ?? "?")≠\(want.sampleAspectRatio ?? "?")")
        }
        if !MatchEvaluator.colorSatisfies(g.colorPrimaries, target: want.colorPrimaries)
            || !MatchEvaluator.colorSatisfies(g.colorTransfer, target: want.colorTransfer)
            || !MatchEvaluator.colorSatisfies(g.colorSpace, target: want.colorSpace)
            || !MatchEvaluator.colorSatisfies(g.colorRange, target: want.colorRange) {
            diffs.append("color")
        }
        return diffs.isEmpty ? "video stream differs" : diffs.joined(separator: ", ")
    }

    private static func filterChain(source: VideoProperties, target: VideoProperties,
                                    repair: String? = nil) -> [String] {
        let srcInterlaced = isInterlaced(source.fieldOrder)
        let tgtInterlaced = isInterlaced(target.fieldOrder)
        var filters: [String] = []

        if srcInterlaced && !tgtInterlaced { filters.append("bwdif=mode=0") }

        filters += scaleAndPad(source: source, target: target)
        filters.append("setsar=\(sarFraction(target.sampleAspectRatio))")
        filters.append("format=\(target.pixelFormat)")

        if let stage = colorStage(source: source, target: target) {
            filters.append(stage)
        }

        if let repair { filters.append(repair) }

        if tgtInterlaced && !srcInterlaced && sourceSuppliesFieldRate(source, target) {
            filters.append("fps=\(fpsToken(target.frameRate, double: true))")
            filters.append("interlace=scan=\(topFieldFirst(target.fieldOrder) ? "tff" : "bff")")
        } else if tgtInterlaced && !srcInterlaced {
            filters.append("fps=\(fpsToken(target.frameRate, double: false))")
            filters.append(BoundaryReencodeEngine.fieldOrderFilter(target.fieldOrder)
                ?? BoundaryReencodeEngine.topFirstScanFilter)
        } else {
            filters.append("fps=\(fpsToken(target.frameRate, double: false))")
        }

        if targetIsUntagged(target) {
            filters.append("setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown:range=unknown")
        }

        if tgtInterlaced, srcInterlaced, BoundaryReencodeEngine.interlaceCapable(target.codec) {
            filters.append(BoundaryReencodeEngine.fieldOrderFilter(target.fieldOrder)
                ?? BoundaryReencodeEngine.topFirstScanFilter)
        }
        return filters
    }

    private static func targetIsUntagged(_ t: VideoProperties) -> Bool {
        t.colorPrimaries == nil && t.colorTransfer == nil && t.colorSpace == nil && t.colorRange == nil
    }

    struct ColorSpec: Equatable {
        var primaries: String
        var transfer: String
        var matrix: String
        var range: String
    }

    static func targetColorSpec(_ t: VideoProperties) -> ColorSpec? {
        guard let p = t.colorPrimaries, let tr = t.colorTransfer, let m = t.colorSpace else { return nil }
        return ColorSpec(primaries: p, transfer: tr, matrix: m, range: t.colorRange ?? "tv")
    }

    static func assumedColorTriple(height: Int, frameRate: String) -> (primaries: String, transfer: String, matrix: String) {
        guard height <= 576 else { return ("bt709", "bt709", "bt709") }
        let den = frameRate.split(separator: "/").compactMap { Int($0) }.last
        return den == 1001
            ? ("smpte170m", "smpte170m", "smpte170m")
            : ("bt470bg", "smpte170m", "bt470bg")
    }

    static func effectiveInputColor(_ s: VideoProperties) -> (spec: ColorSpec, assumed: Bool) {
        let fallback = assumedColorTriple(height: s.height, frameRate: s.frameRate)
        let assumed = s.colorPrimaries == nil || s.colorTransfer == nil || s.colorSpace == nil
        let spec = ColorSpec(primaries: s.colorPrimaries ?? fallback.primaries,
                             transfer: s.colorTransfer ?? fallback.transfer,
                             matrix: s.colorSpace ?? fallback.matrix,
                             range: s.colorRange ?? "tv")
        return (spec, assumed)
    }

    // ADR-0011
    static func colorStage(source: VideoProperties, target: VideoProperties) -> String? {
        guard let tgt = targetColorSpec(target) else { return nil }
        let input = effectiveInputColor(source)
        if input.spec == tgt {
            guard input.assumed else { return nil }
            return "setparams=color_primaries=\(filterColorToken(tgt.primaries))"
                + ":color_trc=\(filterColorToken(tgt.transfer))"
                + ":colorspace=\(filterColorToken(tgt.matrix))"
                + ":range=\(tgt.range)"
        }
        return "colorspace=ispace=\(filterColorToken(input.spec.matrix))"
            + ":iprimaries=\(filterColorToken(input.spec.primaries))"
            + ":itrc=\(filterColorToken(input.spec.transfer))"
            + ":irange=\(input.spec.range)"
            + ":space=\(filterColorToken(tgt.matrix))"
            + ":primaries=\(filterColorToken(tgt.primaries))"
            + ":trc=\(filterColorToken(tgt.transfer))"
            + ":range=\(tgt.range)"
    }

    private static func filterColorToken(_ probed: String) -> String {
        switch probed {
        case "iec61966-2-1": return "srgb"
        case "iec61966-2-4": return "xvycc"
        case "bt2020nc": return "bt2020ncl"
        default: return probed
        }
    }

    static func assumedColorWarning(clipName: String, source: VideoProperties, target: VideoProperties) -> String? {
        guard targetColorSpec(target) != nil else { return nil }
        let input = effectiveInputColor(source)
        guard input.assumed else { return nil }
        let name: String
        switch input.spec.matrix {
        case "bt470bg": name = "BT.601 (625-line)"
        case "smpte170m": name = "BT.601 (525-line)"
        default: name = "BT.709"
        }
        return "“\(clipName)” doesn’t say what color standard it uses — assumed \(name) when converting it to the target’s color."
    }

    private static func scaleAndPad(source: VideoProperties, target: VideoProperties) -> [String] {
        let w = target.width, h = target.height
        if displayAspectsMatch(source: source, target: target) {
            return ["scale=\(w):\(h)"]
        }
        let (cw, ch) = fittedContentSize(source: source, target: target)
        let x = (w - cw) / 2, y = (h - ch) / 2
        return ["scale=\(cw):\(ch)", "pad=\(w):\(h):\(x):\(y)"]
    }

    private static func fittedContentSize(source: VideoProperties, target: VideoProperties) -> (Int, Int) {
        let srcDAR = displayAspect(source)
        let sarf = sarValue(target.sampleAspectRatio)
        let tgtDAR = (Double(target.width) * sarf) / Double(target.height)
        let displayW: Double, displayH: Double
        if srcDAR >= tgtDAR {
            displayW = Double(target.width) * sarf
            displayH = displayW / srcDAR
        } else {
            displayH = Double(target.height)
            displayW = displayH * srcDAR
        }
        return (evenRound(displayW / sarf), evenRound(displayH))
    }

    private static func encoderArgs(target: VideoProperties, crf: Int? = nil,
                                    reorderDepth: Int = 1) -> [String] {
        var args = ["-c:v", EncoderSelection.encoder(for: target.codec),
                    "-profile:v", profile(target)]
        switch target.codec {
        case "hevc":
            if let crf { args += ["-crf", String(crf)] }
            args += ["-x265-params", x265Params(target, reorderDepth: reorderDepth)]
        case "mpeg2video":
            if isInterlaced(target.fieldOrder) {
                args += ["-flags", "+ildct+ilme"]
            }
        default:
            if let crf { args += ["-crf", String(crf)] }
            if let lvl = EncoderSelection.h264Level(target.level) { args += ["-level", lvl] }
            if isInterlaced(target.fieldOrder) {
                args += ["-flags", "+ildct+ilme"]
            }
            args += EncoderSelection.encoderParams(
                EncoderSelection.reorderDepthParams(depth: reorderDepth, forCodec: target.codec),
                forCodec: target.codec)
        }
        if args.count >= 4, args[2] == "-profile:v", args[3].isEmpty {
            args.removeSubrange(2...3)
        }
        if let range = target.colorRange { args += ["-color_range", range] }
        if let spec = targetColorSpec(target) {
            args += ["-color_primaries", spec.primaries, "-color_trc", spec.transfer,
                     "-colorspace", spec.matrix]
        }
        return args
    }

    private static func profile(_ target: VideoProperties) -> String {
        EncoderSelection.encoderProfile(target.profile, codec: target.codec) ?? ""
    }

    private static func x265Params(_ target: VideoProperties, reorderDepth: Int = 1) -> String {
        var p = "log-level=error"
        if let lvl = EncoderSelection.hevcLevel(target.level) {
            p += ":level-idc=\(lvl)"
        }
        for entry in EncoderSelection.reorderDepthParams(depth: reorderDepth, forCodec: target.codec) {
            p += ":\(entry)"
        }
        return p
    }

    // ADR-0011
    static func sourceSuppliesFieldRate(_ source: VideoProperties, _ target: VideoProperties) -> Bool {
        guard let s = frameRateValue(source.frameRate), let t = frameRateValue(target.frameRate) else {
            return false
        }
        return s >= 2 * t - 0.001
    }

    static func isInterlaced(_ field: String?) -> Bool {
        MatchEvaluator.scanDirection(field) != "progressive"
    }

    private static func topFieldFirst(_ field: String?) -> Bool {
        MatchEvaluator.scanDirection(field) == "tff"
    }

    private static func displayAspectsMatch(source: VideoProperties, target: VideoProperties) -> Bool {
        abs(displayAspect(source) - displayAspect(target)) < 0.01
    }

    static func displayAspect(_ v: VideoProperties) -> Double {
        (Double(v.width) / Double(v.height)) * sarValue(v.sampleAspectRatio)
    }

    private static func sarValue(_ sar: String?) -> Double {
        let p = (sar ?? "1:1").split(separator: ":").compactMap { Double($0) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { return 1 }
        return p[0] / p[1]
    }

    private static func sarFraction(_ sar: String?) -> String {
        let p = (sar ?? "1:1").split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { return "1/1" }
        return "\(p[0])/\(p[1])"
    }

    static func fpsToken(_ rate: String, double: Bool) -> String {
        let p = rate.split(separator: "/").compactMap { Int($0) }
        guard p.count == 2, p[1] != 0 else { return double ? "50" : "25" }
        let num = double ? p[0] * 2 : p[0]
        return p[1] == 1 ? "\(num)" : "\(num)/\(p[1])"
    }

    static func frameRateValue(_ rate: String) -> Double? {
        let p = rate.split(separator: "/").compactMap { Double($0) }
        guard p.count == 2, p[1] != 0 else { return nil }
        return p[0] / p[1]
    }

    private static func evenRound(_ x: Double) -> Int {
        let n = Int(x.rounded())
        return n % 2 == 0 ? n : n + 1
    }
}
