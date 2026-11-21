import Foundation

struct ExportItem {
    var source: URL
    var displayName: String = ""
    var codec: String? = nil
    var segments: [PlannedSegment] = []
    var fallbackSegments: [PlannedSegment]? = nil
    var index: FrameIndex = FrameIndex(pts: [], keyframeFlags: [])
    var encoder: [String] = []
    var containerStart: Double = 0
    var frameRate: String? = nil
    var sourceDamaged: Bool = false
    var fieldCoded: Bool = false
    var sourceReorderDepth: Int? = nil
    var audioStart: Double? = nil
    var audioEnd: Double? = nil
    var audioSources: [ExportEngine.AudioSource?] = [.stream(0)]
    var audioMixFilters: [String?] = []
    var audioDuration: Double? = nil
    var conform: ConformEngine.VideoConform? = nil
    var ownTracks: [AudioCodecPolicy.OutputAudioTrack]? = nil
    var truncatedEndingTrim: Double? = nil
}

enum ExportError: LocalizedError {
    case noClips
    case invalidPlan
    case cutFailed(String)
    case conformFailed(String)
    case concatFailed(String)
    case missingSegment
    case verificationFailed(String)
    case destinationIsSource(clip: String, path: String)
    case cancelled(finished: Int, total: Int)
    case clipNotReady(String)
    case fieldCodedPlanNotCopyOnly(clip: String)
    case unknownSilenceLength(clip: String, track: Int)

    var errorDescription: String? {
        switch self {
        case .noClips: return "There are no clips to export."
        case .invalidPlan: return "A clip's in/out points collapse to nothing after snapping to clean cut points."
        case .cutFailed(let d): return "Could not cut a clip.\n\(d)"
        case .conformFailed(let d): return "Could not conform a clip to the target.\n\(d)"
        case .concatFailed(let d): return "Could not join the clips.\n\(d)"
        case .missingSegment: return "The expected output segment was not produced."
        case .verificationFailed(let d): return "The cut did not verify and was not saved.\n\(d)"
        case .destinationIsSource(let clip, let path):
            return "The export would overwrite the source of “\(clip)” at \(path); the original would be destroyed. Choose a different destination."
        case .cancelled: return "The export was cancelled."
        case .clipNotReady(let reason): return reason
        case .fieldCodedPlanNotCopyOnly(let clip):
            return "Internal error: the cut points of “\(clip)” don’t sit on clean copy boundaries, but the clip is field-coded and can only be cut by pure stream copy. Re-mark the in and out points in the cut editor and export again."
        case .unknownSilenceLength(let clip, let track):
            return "Internal error: “\(clip)” has no audio for track \(track) and no known length, so the silence standing in for it can’t be measured. Re-mark the in and out points of that clip and export again."
        }
    }
}

enum ExportEngine {
    static let audioBitrate = "192k"

    enum AudioSource: Equatable {
        case stream(Int)
        case external(URL, stream: Int)
    }

    // ADR-0008, ADR-0020
    static func ptsRefillInputFlags(codec: String?, ext: String, damaged: Bool = false) -> [String] {
        needsPtsRefill(codec: codec, ext: ext, damaged: damaged) ? ["-fflags", "+genpts"] : []
    }

    static func needsPtsRefill(codec: String?, ext: String, damaged: Bool) -> Bool {
        (codec == "mpeg2video" || damaged) && ext.lowercased() == "mkv"
    }

    static func ptsRefillBitstreamFilter(codec: String?, ext: String, damaged: Bool = false) -> [String] {
        needsPtsRefill(codec: codec, ext: ext, damaged: damaged) ? ["-bsf:v", ptsRefillFilter] : []
    }

    static let ptsRefillFilter = "setts=pts=if(eq(PTS\\,NOPTS)\\,DTS\\,PTS)"

    static let parameterSetRepeatFilter = "dump_extra"

    // ADR-0032
    static func parameterSetRepeatFilter(forCopyOf codec: String?) -> String? {
        switch codec {
        case "hevc": return "hevc_mp4toannexb"
        case "h264": return "h264_mp4toannexb"
        default: return nil
        }
    }

    static func copyPieceBitstreamFilter(codec: String?, ext: String, damaged: Bool = false,
                                         inBandParameterSets: Bool = false) -> [String] {
        var chain: [String] = []
        if !damaged, !inBandParameterSets, let repeatFilter = parameterSetRepeatFilter(forCopyOf: codec) {
            chain.append(repeatFilter)
        }
        if !ptsRefillBitstreamFilter(codec: codec, ext: ext, damaged: damaged).isEmpty {
            chain.append(ptsRefillFilter)
        }
        return chain.isEmpty ? [] : ["-bsf:v", chain.joined(separator: ",")]
    }

    static func inBandParameterSetProbeArguments(source: URL, seek: Double, codec: String?) -> [String]? {
        guard parameterSetRepeatFilter(forCopyOf: codec) != nil else { return nil }
        return ["-hide_banner", "-v", "info",
                "-ss", timeString(seek), "-i", source.path,
                "-map", "0:v:0", "-c", "copy", "-bsf:v", "trace_headers",
                "-frames:v", "1", "-f", "null", "-"]
    }

    static func tracesInBandParameterSets(_ trace: String) -> Bool {
        guard let packet = trace.range(of: "Packet:") else { return false }
        let inPacket = trace[packet.upperBound...]
        return inPacket.contains("Sequence Parameter Set") && inPacket.contains("Picture Parameter Set")
    }

    static func needsCut(_ plan: SegmentPlan) -> Bool {
        plan.inSegmentTime != nil || plan.outSegmentTime != nil
    }

    static func isWholeClipCopy(_ plan: [PlannedSegment]) -> Bool {
        plan.count == 1 && plan[0].kind == .copy
            && plan[0].range.lowerBound == 0 && plan[0].outCutKeyframe == nil
    }

    static func pieceExtension(container: String, fieldCoded: Bool, plan: [PlannedSegment]) -> String {
        guard fieldCoded else { return container }
        return isWholeClipCopy(plan) ? container : "ts"
    }

    static func pieceExtensions(container: String, mode: OutputMode, items: [ExportItem]) -> [String] {
        if mode == .connect, items.count > 1, items.contains(where: \.fieldCoded) {
            return Array(repeating: "ts", count: items.count)
        }
        return items.map {
            pieceExtension(container: container, fieldCoded: $0.fieldCoded, plan: $0.segments)
        }
    }

    // ADR-0026
    static func joinReorderDepth(items: [ExportItem]) -> Int {
        items.reduce(1) { deepest, item in
            guard item.conform == nil, item.segments.contains(where: { $0.kind == .copy }) else {
                return deepest
            }
            return max(deepest, item.sourceReorderDepth ?? 1)
        }
    }

    static func pieceReorderDepth(item: ExportItem, joinDepth: Int) -> Int {
        let depth = firstPieceIsEncoded(item) ? joinDepth : (item.sourceReorderDepth ?? 1)
        return min(depth, EncoderSelection.deepestEncodableReorderDepth)
    }

    static func firstPieceIsEncoded(_ item: ExportItem) -> Bool {
        if item.conform != nil { return true }
        return item.segments.first?.kind == .reEncode
    }

    // ADR-0038
    static func spliceFailureFallsBack(_ error: ExportError) -> Bool {
        switch error {
        case .verificationFailed, .cutFailed, .concatFailed, .missingSegment: return true
        default: return false
        }
    }

    static func wantedSegmentIndex(plan: SegmentPlan) -> Int {
        plan.inSegmentTime == nil ? 0 : 1
    }

    // ADR-0027
    static let copyReadMargin = 2.0

    struct CopyHeadSeek: Equatable {
        var seek: Double
        var origin: Double
    }

    static func copyHeadSeekTarget(plan: SegmentPlan, index: FrameIndex,
                                   containerStart: Double) -> Double? {
        guard plan.inSegmentTime != nil,
              let previous = index.keyframeIndex(atOrBefore: plan.inFrame - 1) else { return nil }
        let anchor = index.keyframeIndex(atOrBefore: previous - 1) ?? previous
        return max(0, index.pts[anchor] - containerStart)
    }

    static func cutArguments(source: URL, plan: SegmentPlan, segmentPattern: String,
                             bitstreamFilter: [String] = [], trackTimescale: Int? = nil,
                             headSeek: CopyHeadSeek? = nil, inputFlags: [String] = []) -> [String] {
        var args = ["-v", "error"]
        args += inputFlags
        if let headSeek { args += ["-ss", Self.timeString(headSeek.seek)] }
        args += ["-i", source.path, "-map", "0:v:0", "-c", "copy"]
        args += bitstreamFilter
        args += ["-f", "segment"]
        if let trackTimescale {
            args += ["-segment_format_options", "video_track_timescale=\(trackTimescale)"]
        }
        let origin = headSeek?.origin ?? 0
        let times = [plan.inSegmentTime, plan.outSegmentTime].compactMap { $0 }
        args += ["-segment_times", times.map { Self.timeString($0 - origin) }.joined(separator: ",")]
        args += ["-reset_timestamps", "1"]
        if let out = plan.outSegmentTime {
            args += ["-t", Self.timeString(out + Self.copyReadMargin - origin)]
        }
        args.append(segmentPattern)
        return args
    }

    static func remuxArguments(source: URL, output: URL, bitstreamFilter: [String] = [],
                               trackTimescale: Int? = nil, inputFlags: [String] = []) -> [String] {
        var args = ["-v", "error"] + inputFlags
        args += ["-i", source.path, "-map", "0:v:0", "-c", "copy"]
        args += bitstreamFilter
        if let trackTimescale { args += ["-video_track_timescale", String(trackTimescale)] }
        args.append(output.path)
        return args
    }

    // ADR-0009
    static func exportWideTimescale(probed: [Int]) -> Int? {
        guard !probed.isEmpty else { return nil }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        var acc = 1
        for value in probed where value > 0 {
            let (multiplied, overflow) = acc.multipliedReportingOverflow(by: value / gcd(acc, value))
            guard !overflow, multiplied <= Int(Int32.max) else { return nil }
            acc = multiplied
        }
        return acc > 1 ? acc : nil
    }

    static let timescaleProbeConcurrency = 4

    static func exportWideTimescale(probes: [Int?]) -> Int? {
        guard !probes.isEmpty else { return nil }
        var measured: [Int] = []
        for p in probes {
            guard let p else { return nil }
            measured.append(p)
        }
        return exportWideTimescale(probed: measured)
    }

    private static func probeTrackTimescale(ffmpeg: URL, source: URL, output: URL) async -> Int? {
        guard let result = try? await ProcessRunner.run(
                  ffmpeg, BoundaryReencodeEngine.timescaleProbeArguments(source: source, output: output)),
              result.status == 0 else { return nil }
        return BoundaryReencodeEngine.trackTimescale(timeBase: await MediaProbe.videoTimeBase(url: output))
    }

    private static func probeTrackTimescales(ffmpeg: URL, sources: [URL], work: URL) async -> [Int?] {
        var results = [Int?](repeating: nil, count: sources.count)
        await withTaskGroup(of: (Int, Int?).self) { group in
            var next = 0
            let seed = min(timescaleProbeConcurrency, sources.count)
            while next < seed {
                let i = next
                let source = sources[i]
                let output = work.appendingPathComponent("tsprobe_\(i).mp4")
                group.addTask { (i, await probeTrackTimescale(ffmpeg: ffmpeg, source: source, output: output)) }
                next += 1
            }
            while let (i, ts) = await group.next() {
                results[i] = ts
                if next < sources.count {
                    let j = next
                    let source = sources[j]
                    let output = work.appendingPathComponent("tsprobe_\(j).mp4")
                    group.addTask { (j, await probeTrackTimescale(ffmpeg: ffmpeg, source: source, output: output)) }
                    next += 1
                }
            }
        }
        return results
    }

    static func concatArguments(listFile: URL, output: URL) -> [String] {
        ["-v", "error", "-f", "concat", "-safe", "0", "-i", listFile.path, "-c", "copy", output.path]
    }

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

    static func clipSpans(items: [ExportItem]) -> [Double?] {
        items.enumerated().map { i, item in
            i < items.count - 1 ? clipSpan(item) : nil
        }
    }

    static func crossClipDurations(items: [ExportItem]) -> [Double?] {
        zip(clipSpans(items: items), items).map { span, item in
            item.fieldCoded ? nil : span
        }
    }

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

    static func timestampDefect(pts: [Double]) -> String? {
        timestampDefect(pts: pts, plan: [], sourcePts: [])
    }

    static func timestampDefect(pts: [Double], plan: [PlannedSegment], sourcePts: [Double],
                                outputCounts: [Int]? = nil) -> String? {
        guard pts.count >= 3 else { return nil }
        let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }
        let median = deltas.sorted()[deltas.count / 2]
        guard median > 0 else { return "frames share a timestamp (zero median interval)" }

        let counts = outputCounts ?? plan.map { $0.range.count }
        var starts: [Int] = []
        var total = 0
        for count in counts { starts.append(total); total += count }
        let planApplies = !plan.isEmpty && counts.count == plan.count && total == pts.count
            && !sourcePts.isEmpty
        func segmentIndex(of frame: Int) -> Int {
            var s = plan.count - 1
            while s > 0 && starts[s] > frame { s -= 1 }
            return s
        }
        let seamWindow = 2
        let matchRadius = 3
        func anomalyKind(_ d: Double) -> Int { d <= median * 0.5 ? -1 : (d >= median * 1.5 ? 1 : 0) }
        let sourceDeltas = zip(sourcePts.dropFirst(), sourcePts).map { $0 - $1 }

        for (i, d) in deltas.enumerated() {
            let kind = anomalyKind(d)
            if kind == 0 { continue }
            if planApplies {
                let s = segmentIndex(of: i)
                if plan[s].kind == .copy && segmentIndex(of: i + 1) == s {
                    let within = i - starts[s]
                    let lastInterval = counts[s] - 2
                    let headGuard = s == 0 ? 0 : seamWindow
                    let tailGuard = s == plan.count - 1 ? 0 : seamWindow
                    if within >= headGuard && lastInterval - within >= tailGuard {
                        let m = plan[s].range.lowerBound + within
                        let nearby = (m - matchRadius)...(m + matchRadius)
                        if nearby.contains(where: { $0 >= 0 && $0 < sourceDeltas.count
                            && anomalyKind(sourceDeltas[$0]) == kind }) {
                            continue
                        }
                    }
                }
            }
            if kind == -1 {
                return String(format: "frames at %.3fs and %.3fs are only %.4fs apart (~%.4fs expected — a duplicate)",
                              pts[i], pts[i + 1], d, median)
            }
            return String(format: "a %.4fs gap between %.3fs and %.3fs (~%.4fs expected — a frame slot was skipped)",
                          d, pts[i], pts[i + 1], median)
        }
        return nil
    }

    struct KeptWindow: Equatable {
        var start: Double?
        var end: Double?
        var duration: Double
    }

    // ADR-0014
    static func keptWindow(inPts: Double?, outPts: Double?, outEndPts: Double?,
                           firstPts: Double?, lastPts: Double?,
                           frameDuration: Double?, containerStart: Double) -> KeptWindow {
        let spanStart = inPts ?? firstPts ?? 0
        let closedEnd = outPts.map { outEndPts ?? ($0 + (frameDuration ?? 0)) }
        let spanEnd = closedEnd ?? ((lastPts ?? 0) + (frameDuration ?? 0))
        return KeptWindow(start: inPts.map { max(0, $0 - containerStart) },
                          end: closedEnd.map { max(0, $0 - containerStart) },
                          duration: max(0, spanEnd - spanStart))
    }

    static func audioInputArgs(source: URL, start: Double?, end: Double?) -> [String] {
        var a: [String] = ["-max_error_rate", "1.0"]
        if let start { a += ["-ss", timeString(start)] }
        if let end { a += ["-t", timeString(end - (start ?? 0))] }
        a += ["-i", source.path]
        return a
    }

    private static func keptDuration(_ item: ExportItem) -> Double? {
        if let d = item.audioDuration, d > 0 { return d }
        guard let s = item.audioStart, let e = item.audioEnd, e > s else { return nil }
        return e - s
    }

    static func audioMuxArguments(videoInput: URL?, items: [ExportItem], tracks: [AudioCodecPolicy.OutputAudioTrack],
                                  audioCodec: String, output: URL) -> [String] {
        var args = ["-y", "-v", "error"]
        var nextInput = 0
        if let videoInput {
            args += ["-i", videoInput.path]
            nextInput = 1
        }
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
                let leg = "c\(i)t\(t)"
                let label = "[\(leg)]"
                let samples = keptDuration(item).map { max(1, Int(($0 * Double(track.sampleRate)).rounded())) }
                let source = t < item.audioSources.count ? item.audioSources[t] : nil
                let mix = t < item.audioMixFilters.count ? item.audioMixFilters[t] : nil
                let input: String? = switch source {
                case .stream(let s): "[\(ownInput[i]):a:\(s)]"
                case .external(let url, let s): "[\(externalInput[i][url]!):a:\(s)]"
                case nil: nil
                }
                if let input {
                    chains += legChains(from: input, track: track, samples: samples,
                                        mix: mix, leg: leg)
                } else {
                    chains.append(silenceSource(track) + ",atrim=end_sample=\(samples ?? 1)" + label)
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

    private static func legChains(from input: String, track: AudioCodecPolicy.OutputAudioTrack,
                                  samples: Int?, mix: String?, leg: String) -> [String] {
        let conformed = input + legFilter(track: track, mix: mix)
        guard let n = samples else { return [conformed + "[\(leg)]"] }
        return [conformed + "[\(leg)src]",
                silenceSource(track) + "[\(leg)pad]",
                "[\(leg)src][\(leg)pad]concat=n=2:v=0:a=1,atrim=end_sample=\(n)[\(leg)]"]
    }

    private static func legFilter(track: AudioCodecPolicy.OutputAudioTrack,
                                  mix: String? = nil) -> String {
        let conform = ConformEngine.audioFilter(sampleRate: track.sampleRate,
                                                channels: track.channels, fillGaps: true)
        return mix.map { $0 + "," + conform } ?? conform
    }

    private static func silenceSource(_ track: AudioCodecPolicy.OutputAudioTrack) -> String {
        "anullsrc=r=\(track.sampleRate):cl=\(ConformEngine.channelLayout(track.channels))"
    }

    static func assertAudioLegLengthsKnown(items: [ExportItem],
                                           tracks: [AudioCodecPolicy.OutputAudioTrack],
                                           mode: OutputMode) throws {
        for item in items where keptDuration(item) == nil {
            let itemTracks = mode == .separate ? (item.ownTracks ?? tracks) : tracks
            for t in itemTracks.indices
            where t >= item.audioSources.count || item.audioSources[t] == nil {
                throw ExportError.unknownSilenceLength(clip: item.displayName, track: t + 1)
            }
        }
    }

    static let audioExtentToleranceFrames = 3.0

    static let nominalAudioFrame = 1024.0 / 48000.0

    static func audioTimelineDefect(timelines: [MediaProbe.AudioTimeline],
                                    expectedTracks: Int,
                                    expectedExtent: Double?) -> String? {
        guard expectedTracks > 0 else { return nil }
        guard timelines.count == expectedTracks else {
            return "The finished file carries \(timelines.count) audio track"
                + "\(timelines.count == 1 ? "" : "s") but the export rebuilt \(expectedTracks)."
        }
        for (t, timeline) in timelines.enumerated() {
            if let stall = timeline.firstNonAdvance {
                return String(format: "The rebuilt audio of track %d stops advancing: packet %d is stamped %.3fs, no later than the packet before it (%.3fs).",
                              t + 1, stall.ordinal, stall.pts, stall.previous)
            }
            guard timeline.extent(nominalInterval: nominalAudioFrame) != nil else {
                return "The rebuilt audio of track \(t + 1) carries no timestamped audio"
                    + " (\(timeline.untimedPackets) packet\(timeline.untimedPackets == 1 ? "" : "s"), none timestamped)."
            }
        }
        guard let expectedExtent else { return nil }
        for (t, timeline) in timelines.enumerated() {
            guard let measured = timeline.extent(nominalInterval: nominalAudioFrame) else { continue }
            let tolerance = audioExtentToleranceFrames
                * (timeline.packetInterval ?? nominalAudioFrame)
            guard abs(measured - expectedExtent) <= tolerance else {
                return String(format: "The rebuilt audio of track %d measures %.3fs but the clips keep %.3fs (allowed to differ by %.3fs).",
                              t + 1, measured, expectedExtent, tolerance)
            }
        }
        return nil
    }

    static func verifyWrittenAudio(_ output: URL, expectedTracks: Int,
                                   expectedExtent: Double?) async throws {
        let timelines: [MediaProbe.AudioTimeline]
        do {
            timelines = try await MediaProbe.audioTimelines(url: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw ExportError.verificationFailed("The rebuilt audio could not be read back from the finished file.\n\(detail)")
        }
        guard let defect = audioTimelineDefect(timelines: timelines, expectedTracks: expectedTracks,
                                               expectedExtent: expectedExtent) else { return }
        try? FileManager.default.removeItem(at: output)
        throw ExportError.verificationFailed(defect)
    }

    static func timeString(_ t: Double) -> String {
        var s = String(format: "%.6f", t)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    static func plannedOutputs(items: [ExportItem], settings: OutputSettings, ext: String,
                               audioCodec: String, to destination: URL) -> [(clip: String, url: URL)] {
        switch settings.mode {
        case .connect:
            return [(items.first?.displayName ?? "", destination)]
        case .separate:
            let exts = items.map { item in
                settings.type == .audioOnly
                    ? AudioCodecPolicy.audioFileExtension(forEncoder: item.ownTracks?.first?.encoder ?? audioCodec)
                    : ext
            }
            let names = separateFileNames(clipNames: items.map(\.displayName), exts: exts)
            return zip(items, names).map { (clip: $0.displayName, url: destination.appendingPathComponent($1)) }
        }
    }

    static func assertNoSourceCollision(items: [ExportItem], outputs: [(clip: String, url: URL)]) throws {
        var sources: [(clip: String, url: URL)] = []
        for item in items {
            sources.append((item.displayName, item.source))
            for case .external(let url, _)? in item.audioSources {
                sources.append((item.displayName, url))
            }
        }
        for output in outputs {
            for source in sources where denotesSameFile(output.url, source.url) {
                throw ExportError.destinationIsSource(clip: source.clip, path: output.url.path)
            }
        }
    }

    static func denotesSameFile(_ a: URL, _ b: URL) -> Bool {
        if resolvedOutputPath(a) == resolvedOutputPath(b) { return true }
        let fm = FileManager.default
        guard fm.fileExists(atPath: a.path), fm.fileExists(atPath: b.path),
              let ida = (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier,
              let idb = (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        else { return false }
        return (ida as? NSObject)?.isEqual(idb) ?? false
    }

    static func resolvedOutputPath(_ url: URL) -> String {
        let std = url.standardizedFileURL
        let parent = std.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(std.lastPathComponent)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func export(
        items: [ExportItem],
        settings: OutputSettings,
        audioCodec: String = AudioCodecPolicy.fallbackAudioCodec,
        tracks: [AudioCodecPolicy.OutputAudioTrack] = [AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2)],
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        log: @escaping (String) -> Void = { _ in },
        pieceCache: PieceCache? = nil
    ) async throws {
        guard !items.isEmpty else { throw ExportError.noClips }
        let wantsVideo = settings.type != .audioOnly
        if wantsVideo {
            guard items.allSatisfy({ !$0.segments.isEmpty || $0.conform != nil }) else {
                throw ExportError.invalidPlan
            }
        }

        let ffmpeg = try FFTools.ffmpegURL()
        let ext = AudioCodecPolicy.outputExtension(type: settings.type, container: settings.container, audioEncoder: audioCodec)
        let outputs = plannedOutputs(items: items, settings: settings, ext: ext,
                                     audioCodec: audioCodec, to: destination)
        try assertNoSourceCollision(items: items, outputs: outputs)
        let wantsAudio = settings.type != .videoOnly
        if wantsAudio {
            try assertAudioLegLengthsKnown(items: items, tracks: tracks, mode: settings.mode)
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        WorkDirectorySweeper.claim(work)
        defer { try? FileManager.default.removeItem(at: work) }

        var currentOutput: URL? = nil
        var finishedFiles = 0
        do {
        var videoPieces: [URL] = []
        if wantsVideo {
            var exportTimescale: Int? = nil
            if ext.lowercased() == "mp4" {
                let probes = await probeTrackTimescales(
                    ffmpeg: ffmpeg, sources: items.map(\.source), work: work)
                exportTimescale = exportWideTimescale(probes: probes)
            }
            let pieceExts = pieceExtensions(container: ext, mode: settings.mode, items: items)
            let joinDepth = settings.mode == .connect
                ? joinReorderDepth(items: items)
                : nil
            for (i, item) in items.enumerated() {
                let withinClip: @Sendable (Double) -> Void = { w in
                    progress(ExportProgress.clipFraction(clipIndex: i, clipCount: items.count, withinClip: w))
                }
                let depth = pieceReorderDepth(
                    item: item, joinDepth: joinDepth ?? joinReorderDepth(items: [item]))
                let clipClock = StageClock()
                if let conform = item.conform {
                    videoPieces.append(try await ConformEngine.produceConformedPiece(
                        ffmpeg, source: item.source, conform: conform,
                        start: item.audioStart, end: item.audioEnd, work: work,
                        ext: pieceExts[i], clipIndex: i, displayName: item.displayName,
                        trackTimescale: exportTimescale, reorderDepth: depth,
                        onProgress: withinClip, log: log, pieceCache: pieceCache))
                } else {
                    func produce(_ plan: [PlannedSegment]) async throws -> URL {
                        try await BoundaryReencodeEngine.produceVideoPiece(
                            ffmpeg, source: item.source, plan: plan, index: item.index,
                            encoder: item.encoder, work: work, ext: pieceExts[i], clipIndex: i,
                            displayName: item.displayName, codec: item.codec, trackTimescale: exportTimescale,
                            containerStart: item.containerStart, frameRate: item.frameRate,
                            sourceDamaged: item.sourceDamaged,
                            fieldCoded: item.fieldCoded, reorderDepth: depth,
                            onProgress: withinClip, log: log, pieceCache: pieceCache)
                    }
                    do {
                        videoPieces.append(try await produce(item.segments))
                    } catch let error as ExportError {
                        // ADR-0038
                        guard let fallback = item.fallbackSegments,
                              Self.spliceFailureFallsBack(error) else { throw error }
                        log("clip \(i) in-point splice refused; rendering with the copy-safe "
                            + "in-point rule: \(error.localizedDescription.prefix(300))")
                        let fm = FileManager.default
                        for name in (try? fm.contentsOfDirectory(atPath: work.path)) ?? []
                        where name.hasPrefix("c\(i)_") {
                            try? fm.removeItem(at: work.appendingPathComponent(name))
                        }
                        videoPieces.append(try await produce(fallback))
                    }
                }
                log("clip \(i) done (\(i + 1)/\(items.count)): \(clipClock.label)")
                progress(0.7 * Double(i + 1) / Double(items.count))
            }
        }
        let totalSpan: Double? = items.reduce(0.0 as Double?) { acc, item in
            guard let acc, let d = keptDuration(item) else { return nil }
            return acc + d
        }

        switch settings.mode {
        case .connect:
            var videoInput: URL? = nil
            if wantsVideo {
                if videoPieces.count == 1 {
                    videoInput = wantsAudio ? videoPieces[0]
                        : try await containerReadyPiece(videoPieces[0], ext: ext, item: items[0],
                                                        ffmpeg: ffmpeg, work: work,
                                                        name: "joined_video")
                } else {
                    let joined = work.appendingPathComponent("joined_video.\(ext)")
                    let joinClock = StageClock()
                    try await concatVideo(ffmpeg, pieces: videoPieces, items: items, to: joined, work: work)
                    log("Joined \(StageClock.count(videoPieces.count, "piece")): \(joinClock.label)")
                    videoInput = joined
                }
            }
            currentOutput = destination
            if wantsAudio {
                let muxClock = StageClock()
                try await runFFmpeg(ffmpeg, audioMuxArguments(videoInput: videoInput, items: items, tracks: tracks, audioCodec: audioCodec, output: destination),
                                    failure: ExportError.concatFailed) { t in
                    progress(ExportProgress.muxFraction(
                        withinMux: ExportProgress.runFraction(outTime: t, expectedSeconds: totalSpan)))
                }
                log("Muxed audio: \(muxClock.label)")
                let audioVerifyClock = StageClock()
                try await verifyWrittenAudio(destination, expectedTracks: tracks.count,
                                             expectedExtent: totalSpan)
                log("Verified audio: \(audioVerifyClock.label)")
            } else {
                try placeFile(videoInput!, at: destination)
            }

        case .separate:
            for (i, item) in items.enumerated() {
                let out = outputs[i].url
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
                    try await verifyWrittenAudio(out, expectedTracks: itemTracks.count,
                                                 expectedExtent: keptDuration(item))
                } else {
                    try placeFile(try await containerReadyPiece(videoInput!, ext: ext, item: item,
                                                                ffmpeg: ffmpeg, work: work,
                                                                name: "rewrapped_\(i)"),
                                  at: out)
                }
                currentOutput = nil
                finishedFiles = i + 1
                progress(0.7 + 0.3 * Double(i + 1) / Double(items.count))
            }
        }
        } catch is CancellationError {
            if let currentOutput { try? FileManager.default.removeItem(at: currentOutput) }
            throw ExportError.cancelled(
                finished: finishedFiles,
                total: settings.mode == .separate ? items.count : 1)
        }
        progress(1.0)
    }

    private static func containerReadyPiece(_ piece: URL, ext: String, item: ExportItem,
                                            ffmpeg: URL, work: URL, name: String) async throws -> URL {
        guard piece.pathExtension.lowercased() != ext.lowercased() else { return piece }
        let rewrapped = work.appendingPathComponent("\(name).\(ext)")
        try await concatVideo(ffmpeg, pieces: [piece], items: [item], to: rewrapped, work: work)
        return rewrapped
    }

    private static func concatVideo(_ ffmpeg: URL, pieces: [URL], items: [ExportItem], to output: URL, work: URL) async throws {
        let listFile = work.appendingPathComponent("concat-\(UUID().uuidString).txt")
        try concatListContents(pieces: pieces, durations: crossClipDurations(items: items))
            .write(to: listFile, atomically: true, encoding: .utf8)
        try await runFFmpeg(ffmpeg, concatArguments(listFile: listFile, output: output), failure: ExportError.concatFailed)
    }

    static func separateFileNames(clipNames: [String], ext: String) -> [String] {
        separateFileNames(clipNames: clipNames, exts: Array(repeating: ext, count: clipNames.count))
    }

    static func separateFileNames(clipNames: [String], exts: [String]) -> [String] {
        var taken = Set<String>()
        return clipNames.enumerated().map { i, name in
            separateFileName(clipName: name, position: i + 1, count: clipNames.count,
                             ext: exts[i], taken: &taken)
        }
    }

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

    private static func placeFile(_ src: URL, at dest: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: src, to: dest)
    }

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
