import Foundation

enum ClipDoctorEngine {
    struct AudioTrack: Equatable {
        var streamIndex: Int
        var sampleRate: Int
        var encoder: String
        var bitrate: Int
        var heAAC: Bool
    }

    struct Verdict: Equatable {
        enum Outcome { case clean, zonesRemain, inconclusive, notVerified }
        var outcome: Outcome
        var survivingZones: [DamageZone]
        var message: String
        var clean: Bool { outcome == .clean }
    }

    struct Result {
        var output: URL
        var verdict: Verdict
        var repairedZoneCount: Int
        var truncatedEndingTrim: Double? = nil
    }

    enum DoctorError: LocalizedError {
        case destinationExists(URL)
        case destinationIsSource
        case fieldOrderUndetermined
        case unsupportedFieldCodedCodec(String?)

        var errorDescription: String? {
            switch self {
            case .destinationExists(let url):
                return "A repaired file already exists at \(url.lastPathComponent); it was not replaced."
            case .destinationIsSource:
                return "The repaired file would overwrite the source; refusing."
            case .fieldOrderUndetermined:
                return "This clip’s field order couldn’t be determined, so it can’t be safely repaired — "
                    + "repairing it could reverse the fields. It needs a known top- or bottom-field-first scan direction."
            case .unsupportedFieldCodedCodec(let codec):
                let named = codec.map { "\(displayCodecName($0)) " } ?? ""
                return "Field-coded \(named)clips can’t be repaired yet — Clip Doctor’s field-coded repair "
                    + "currently supports H.264 sources only."
            }
        }
    }

    static func repairedSibling(of source: URL) -> URL {
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        return source.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_repaired").appendingPathExtension(ext)
    }

    // ADR-0022
    static func damageToEOFPlan(_ segments: [PlannedSegment], index: FrameIndex,
                                zones: [DamageZone]) -> [PlannedSegment] {
        guard let firstRepair = segments.firstIndex(where: { $0.kind == .reEncode }) else {
            return segments
        }
        let seam = index.keyframeIndex(atOrBefore: segments[firstRepair].range.lowerBound) ?? 0
        var plan: [PlannedSegment] = []
        if seam > 0 {
            plan.append(PlannedSegment(kind: .copy, range: 0..<seam, outCutKeyframe: nil))
        }
        plan.append(PlannedSegment(kind: .reEncode, range: seam..<index.count,
                                   outCutKeyframe: nil, damage: zones.filter(\.affectsVideo)))
        return plan
    }

    static func fieldCodedRepair(
        from segments: [PlannedSegment], index: FrameIndex, zones: [DamageZone],
        fieldOrder: String?
    ) -> (plan: [PlannedSegment], encoder: [String]) {
        (damageToEOFPlan(segments, index: index, zones: zones),
         BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: fieldOrder))
    }

    static func canRepairFieldCoded(codec: String?) -> Bool {
        FieldCodedSupport.canRepairFieldCoded(codec: codec)
    }

    static func isDefiniteFieldOrder(_ fieldOrder: String?) -> Bool {
        switch fieldOrder {
        case "tt", "tb", "bb", "bt": return true
        default: return false
        }
    }

    static func fieldOrderDetectionArguments(source: URL, frames: Int = 500) -> [String] {
        ["-v", "info", "-i", source.path, "-vf", "idet",
         "-frames:v", String(frames), "-an", "-f", "null", "-"]
    }

    struct IdetTally: Equatable { var tff, bff, progressive, undetermined: Int }

    static func parseIdetTally(_ stderr: String) -> IdetTally? {
        let lines = stderr.split(whereSeparator: \.isNewline)
        guard let line = lines.last(where: { $0.contains("Multi frame detection:") }) else { return nil }
        func count(_ key: String) -> Int? {
            guard let r = line.range(of: key) else { return nil }
            let rest = line[r.upperBound...].drop { $0 == ":" || $0 == " " }
            return Int(rest.prefix { $0.isNumber })
        }
        guard let tff = count("TFF"), let bff = count("BFF"),
              let prog = count("Progressive"), let und = count("Undetermined") else { return nil }
        return IdetTally(tff: tff, bff: bff, progressive: prog, undetermined: und)
    }

    static func fieldOrderFromIdet(_ tally: IdetTally) -> String? {
        let interlaced = tally.tff + tally.bff
        let total = interlaced + tally.progressive + tally.undetermined
        guard total >= 100, interlaced * 2 >= total else { return nil }
        let winner = max(tally.tff, tally.bff)
        guard winner * 10 >= interlaced * 9 else { return nil }
        return tally.tff >= tally.bff ? "tt" : "bb"
    }

    static func audioTrack(from detail: MediaProbe.AudioStreamDetail,
                           audioStreamIndex: Int) -> AudioTrack {
        let isHE = detail.codecName == "aac"
            && (detail.profile?.range(of: "HE", options: .caseInsensitive) != nil)
        // ADR-0021
        let encoder = detail.codecName == "aac"
            ? (isHE ? "aac_at" : "aac")
            : (AudioCodecPolicy.audioEncoder(for: detail.codecName) ?? AudioCodecPolicy.fallbackAudioCodec)
        let bitrate = detail.bitrate ?? (detail.channels <= 1 ? 96_000 : 128_000)
        return AudioTrack(streamIndex: audioStreamIndex, sampleRate: detail.sampleRate,
                          encoder: encoder, bitrate: bitrate, heAAC: isHE)
    }

    static func repairedMuxArguments(videoPiece: URL, source: URL,
                                     tracks: [AudioTrack], output: URL) -> [String] {
        var args = ["-y", "-v", "error", "-i", videoPiece.path,
                    "-max_error_rate", "1.0", "-i", source.path]
        let chains = tracks.enumerated().map { t, track in
            "[1:a:\(track.streamIndex)]aresample=\(track.sampleRate):async=1[a\(t)]"
        }
        if !chains.isEmpty { args += ["-filter_complex", chains.joined(separator: ";")] }
        args += ["-map", "0:v:0", "-c:v", "copy"]
        for t in tracks.indices { args += ["-map", "[a\(t)]"] }
        for (t, track) in tracks.enumerated() {
            args += ["-c:a:\(t)", track.encoder]
            if track.heAAC { args += ["-profile:a:\(t)", "4"] }
            args += ["-b:a:\(t)", String(track.bitrate)]
        }
        args.append(output.path)
        return args
    }

    static func makeVerdict(clipName: String, scanned: Bool,
                            cancelled: Bool = false, survivingZones: [DamageZone]) -> Verdict {
        guard scanned else {
            if cancelled {
                return Verdict(outcome: .notVerified, survivingZones: [],
                               message: "Repaired “\(clipName)” and saved the file. Verification was cancelled, so it hasn’t been checked yet.")
            }
            return Verdict(outcome: .inconclusive, survivingZones: [],
                           message: "Repaired “\(clipName)”, but the output could not be re-scanned to verify — the file was kept.")
        }
        guard !survivingZones.isEmpty else {
            return Verdict(outcome: .clean, survivingZones: [],
                           message: "Repaired “\(clipName)” — re-scanned clean, no damage zones remain.")
        }
        let shown = survivingZones.prefix(6).map { ExportPlanner.formattedClipTime($0.start) }
        let times = shown.joined(separator: ", ") + (survivingZones.count > 6 ? ", …" : "")
        let noun = survivingZones.count == 1 ? "damage zone remains" : "damage zones remain"
        return Verdict(outcome: .zonesRemain, survivingZones: survivingZones,
                       message: "Repaired “\(clipName)”, but \(survivingZones.count) \(noun) after re-scan at \(times) — the file was kept for review.")
    }

    static func omittedStreamsNotice(_ streams: [MediaProbe.OtherStream]) -> String? {
        guard !streams.isEmpty else { return nil }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for stream in streams {
            let kind = displayKind(stream.kind)
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
        }
        let phrases = order.map { kind -> String in
            let n = counts[kind] ?? 0
            return "\(n) \(kind) \(n == 1 ? "stream" : "streams")"
        }
        return "\(listPhrase(phrases)) won’t be carried into the repaired copy — Clip Doctor copies video and audio only."
    }

    static func fieldCodedReencodeNotice(clipName: String, duration: Double?) -> String {
        let base = "“\(clipName)” stores two half-pictures per frame, so it can’t be repaired in place — "
            + "the whole clip is re-encoded from the first damage to the end. The result is "
            + "high-quality but not bit-for-bit identical to the source."
        guard let duration, duration > 0 else { return base }
        return base + " Expect roughly \(roughDurationPhrase(duration / 4.5)) on this Mac, "
            + "and up to about \(roughDurationPhrase(duration)) on a slow or busy one."
    }

    private static func roughDurationPhrase(_ seconds: Double) -> String {
        if seconds < 90 { return "a minute or two" }
        if seconds < 3300 {
            let m = max(2, Int((seconds / 60).rounded()))
            return "\(m) minutes"
        }
        return ExportProgress.halfHourPhrase(seconds)
    }

    static func suggestionBannerText(clipName: String, zoneCount: Int) -> String {
        let zones = zoneCount == 1 ? "a damage zone" : "\(zoneCount) damage zones"
        return "“\(clipName)” has \(zones). Clip Doctor can repair it."
    }

    private static func displayCodecName(_ codec: String) -> String {
        switch codec {
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "mpeg2video": return "MPEG-2"
        default: return codec.uppercased()
        }
    }

    private static func displayKind(_ codecType: String) -> String {
        switch codecType {
        case "subtitle": return "subtitle"
        case "data": return "data"
        case "attachment": return "attachment"
        default: return codecType
        }
    }

    private static func listPhrase(_ phrases: [String]) -> String {
        switch phrases.count {
        case 0: return ""
        case 1: return phrases[0]
        case 2: return "\(phrases[0]) and \(phrases[1])"
        default: return phrases.dropLast().joined(separator: ", ") + " and \(phrases.last!)"
        }
    }

    static func repair(
        source: URL, clip: Clip, index: FrameIndex, containerStart: Double,
        destination: URL? = nil, overwrite: Bool = false,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Result {
        guard let video = clip.video else { throw ExportError.invalidPlan }
        let fieldCoded = clip.fieldCoded == true
        if fieldCoded, !canRepairFieldCoded(codec: video.codec) {
            throw DoctorError.unsupportedFieldCodedCodec(video.codec)
        }

        let dest = destination ?? repairedSibling(of: source)
        guard !ExportEngine.denotesSameFile(dest, source) else {
            throw DoctorError.destinationIsSource
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) && !overwrite {
            throw DoctorError.destinationExists(dest)
        }

        let ffmpeg = try FFTools.ffmpegURL()
        let ext = source.pathExtension.lowercased()

        var wholeFile = clip
        wholeFile.inPoint = nil
        wholeFile.outPoint = nil
        let treatment = try ExportPlanner.videoTreatment(
            for: wholeFile, target: nil, index: index, containerStart: containerStart,
            purpose: .repair)
        guard case .smartRender(let segments, let progressiveEncoder) = treatment else {
            throw ExportError.invalidPlan
        }
        let plan: [PlannedSegment]
        let encoder: [String]
        if fieldCoded {
            let order = try await resolveFieldOrder(ffmpeg, source: source, declared: video.fieldOrder)
            (plan, encoder) = fieldCodedRepair(
                from: segments, index: index, zones: clip.damageZones ?? [], fieldOrder: order)
        } else {
            plan = segments
            encoder = progressiveEncoder
        }

        let details = await MediaProbe.audioStreamDetails(url: source)
        let tracks = details.enumerated().map { audioTrack(from: $1, audioStreamIndex: $0) }

        let work = fm.temporaryDirectory
            .appendingPathComponent("clipstitcher-doctor-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let staged = dest.deletingLastPathComponent()
            .appendingPathComponent("clipstitcher-doctor-staging-\(UUID().uuidString).\(ext)")
        defer {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: staged)
        }

        let videoPiece = try await BoundaryReencodeEngine.produceVideoPiece(
            ffmpeg, source: source, plan: plan, index: index, encoder: encoder,
            work: work, ext: ext, clipIndex: 0, displayName: clip.displayName,
            codec: video.codec,
            containerStart: containerStart, frameRate: video.frameRate,
            sourceDamaged: true, copyStrategy: .boundedKeyframe, fieldCoded: fieldCoded,
            reorderDepth: fieldCoded ? nil : (video.reorderDepth ?? 1),
            onProgress: { w in progress(0.85 * w) })

        let totalSpan = clip.duration ?? index.durationSpan
        try await runFFmpeg(ffmpeg, repairedMuxArguments(
            videoPiece: videoPiece, source: source, tracks: tracks, output: staged)) { t in
            progress(0.85 + 0.12 * ExportProgress.runFraction(outTime: t, expectedSeconds: totalSpan))
        }

        let finalDest: URL
        if fm.fileExists(atPath: dest.path) {
            finalDest = try fm.replaceItemAt(dest, withItemAt: staged) ?? dest
        } else {
            try fm.moveItem(at: staged, to: dest)
            finalDest = dest
        }
        progress(0.97)

        let verifyDuration = clip.duration ?? index.durationSpan
        let verdict = await verifyOutput(
            finalDest, clipName: clip.displayName, expectedDuration: verifyDuration
        ) { f in progress(0.97 + 0.03 * f) }
        progress(1.0)
        let trimEnd = ExportPlanner.truncatedEndingTrim(
            for: wholeFile, index: index, containerStart: containerStart, windowStart: nil)
        return Result(output: finalDest, verdict: verdict,
                      repairedZoneCount: (clip.damageZones ?? []).count,
                      truncatedEndingTrim: trimEnd)
    }

    // ADR-0021
    static func verifyOutput(
        _ output: URL, clipName: String, expectedDuration: Double?,
        onScanProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> Verdict {
        do {
            try Task.checkCancellation()
            let effectiveDuration: Double?
            if let expectedDuration, expectedDuration > 0 {
                effectiveDuration = expectedDuration
            } else {
                effectiveDuration = try? await MediaProbe.probe(url: output).duration
            }
            try Task.checkCancellation()
            let scan = try await FrameIndexer.scanAllStreams(
                url: output, expectedDuration: effectiveDuration, onProgress: onScanProgress)
            try Task.checkCancellation()
            let outStart = await MediaProbe.containerStartTime(url: output)
            let surviving = await DamageDetector.detectZones(
                url: output, scan: scan, containerStart: outStart)
            try Task.checkCancellation()
            return makeVerdict(clipName: clipName, scanned: true, survivingZones: surviving)
        } catch is CancellationError {
            return makeVerdict(clipName: clipName, scanned: false, cancelled: true, survivingZones: [])
        } catch {
            return makeVerdict(clipName: clipName, scanned: false, cancelled: false, survivingZones: [])
        }
    }

    private static func resolveFieldOrder(_ ffmpeg: URL, source: URL, declared: String?) async throws -> String {
        if let declared, isDefiniteFieldOrder(declared) { return declared }
        let result = try await ProcessRunner.run(ffmpeg, fieldOrderDetectionArguments(source: source))
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        guard let tally = parseIdetTally(stderr), let order = fieldOrderFromIdet(tally) else {
            throw DoctorError.fieldOrderUndetermined
        }
        return order
    }

    private static func runFFmpeg(_ ffmpeg: URL, _ args: [String],
                                  onOutTime: @escaping @Sendable (Double) -> Void) async throws {
        let parser = ProgressParser()
        let result = try await ProcessRunner.run(
            ffmpeg, ExportProgress.progressArguments(args)
        ) { chunk in
            if let t = parser.feed(chunk) { onOutTime(t) }
        }
        guard result.status == 0 else {
            throw ExportError.cutFailed(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
    }
}
