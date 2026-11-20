import Foundation

enum DamageDetector {
    struct Anomaly: Equatable {
        var start: Double
        var end: Double
        var isVideo: Bool
        var needsDecodeConfirm: Bool = false
    }

    struct Candidate: Equatable {
        var start: Double
        var end: Double
        var hasVideoAnomaly: Bool
        var hasOpaqueVideoAnomaly: Bool = false
        var hasAudioAnomaly: Bool = false
    }

    private static let minIntervals = 30

    private static let tailLookahead = 1.5

    // ADR-0033
    static func anomalies(streams: [FrameIndexer.StreamPackets]) -> [Anomaly] {
        var found: [Anomaly] = []
        for stream in streams {
            if stream.isVideo {
                var seq: [Double] = []
                for p in stream.packets {
                    if let t = p.dts {
                        seq.append(t)
                    } else if p.pts == nil, let last = seq.last {
                        found.append(Anomaly(start: last, end: last, isVideo: true))
                    }
                }
                if let median = medianInterval(seq) {
                    let deltas = zip(seq.dropFirst(), seq).map { $0 - $1 }
                    found += videoGapAnomalies(seq: seq, deltas: deltas, median: median)
                    for (i, d) in deltas.enumerated() where d <= median * 0.25 {
                        found.append(Anomaly(start: min(seq[i], seq[i + 1]),
                                             end: max(seq[i], seq[i + 1]), isVideo: true))
                    }
                } else {
                    let pts = stream.packets.compactMap(\.pts).sorted()
                    guard let median = medianInterval(pts) else { continue }
                    let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }
                    found += videoGapAnomalies(seq: pts, deltas: deltas, median: median)
                }
            } else {
                let seq = stream.packets.compactMap { $0.pts ?? $0.dts }.sorted()
                guard let median = medianInterval(seq) else { continue }
                for (i, d) in zip(seq.dropFirst(), seq).map({ $0 - $1 }).enumerated()
                where d >= median * 1.8 {
                    found.append(Anomaly(start: seq[i], end: seq[i] + d, isVideo: false))
                }
            }
        }
        return found.sorted { $0.start < $1.start }
    }

    static func clusterCandidates(_ anomalies: [Anomaly],
                                  mergeDistance: Double = 2.0) -> [Candidate] {
        var clusters: [Candidate] = []
        for a in anomalies.sorted(by: { $0.start < $1.start }) {
            let opaqueVideo = a.isVideo && !a.needsDecodeConfirm
            if var last = clusters.last, a.start - last.end <= mergeDistance {
                last.end = max(last.end, a.end)
                last.hasVideoAnomaly = last.hasVideoAnomaly || a.isVideo
                last.hasOpaqueVideoAnomaly = last.hasOpaqueVideoAnomaly || opaqueVideo
                last.hasAudioAnomaly = last.hasAudioAnomaly || !a.isVideo
                clusters[clusters.count - 1] = last
            } else {
                clusters.append(Candidate(start: a.start, end: a.end,
                                          hasVideoAnomaly: a.isVideo,
                                          hasOpaqueVideoAnomaly: opaqueVideo,
                                          hasAudioAnomaly: !a.isVideo))
            }
        }
        return clusters
    }

    static func videoGapAnomalies(seq: [Double], deltas: [Double], median: Double,
                                  window: Int = 201) -> [Anomaly] {
        var found: [Anomaly] = []
        var runStart: Int? = nil
        func closeRun(before endExclusive: Int) {
            guard let rs = runStart else { return }
            runStart = nil
            guard endExclusive - rs >= window / 2,
                  endExclusive < deltas.count,
                  deltas[endExclusive] < median * 1.8
            else { return }
            found.append(Anomaly(start: seq[rs], end: seq[endExclusive], isVideo: true,
                                 needsDecodeConfirm: true))
        }
        for (i, d) in deltas.enumerated() {
            if d >= median * 1.8 {
                if d >= 1.8 * Swift.max(median, localMedian(deltas, around: i, window: window)) {
                    closeRun(before: i)
                    found.append(Anomaly(start: seq[i], end: seq[i] + d, isVideo: true,
                                         needsDecodeConfirm: true))
                } else if runStart == nil {
                    runStart = i
                }
            } else {
                closeRun(before: i)
            }
        }
        closeRun(before: deltas.count)
        return found
    }

    static func localMedian(_ deltas: [Double], around index: Int, window: Int = 201) -> Double {
        let half = window / 2
        let lo = max(0, index - half), hi = min(deltas.count - 1, index + half)
        guard hi - lo >= 8 else { return 0 }
        let slice = deltas[lo...hi].sorted()
        return slice[slice.count / 2]
    }

    static func medianInterval(_ seq: [Double]) -> Double? {
        guard seq.count > minIntervals else { return nil }
        let deltas = zip(seq.dropFirst(), seq).map { $0 - $1 }
        let median = deltas.sorted()[deltas.count / 2]
        return median > 0 ? median : nil
    }

    static func marginInterval(frames: [DecodedFrame], candidate: Candidate) -> Double? {
        var deltas: [Double] = []
        for region in [frames.filter { $0.pts < candidate.start - 0.2 },
                       frames.filter { $0.pts > candidate.end + 0.2 }] {
            deltas += zip(region.dropFirst(), region).map { $0.pts - $1.pts }
        }
        guard deltas.count >= 8 else { return nil }
        let median = deltas.sorted()[deltas.count / 2]
        return median > 0 ? median : nil
    }

    struct DecodedFrame: Equatable {
        var pts: Double
        var corrupt: Bool
    }

    static func parseConfirmDecode(stderr: String) -> [DecodedFrame] {
        var frames: [DecodedFrame] = []
        var corruptNext = false
        stderr.enumerateLines { line, _ in
            if line.contains("corrupt decoded frame")
                || line.contains("Error submitting packet to decoder") {
                corruptNext = true
            }
            guard line.contains("Parsed_showinfo"),
                  let range = line.range(of: "pts_time:") else { return }
            let tail = line[range.upperBound...]
            guard let pts = Double(tail.prefix(while: { !$0.isWhitespace })) else { return }
            frames.append(DecodedFrame(pts: pts, corrupt: corruptNext))
            corruptNext = false
        }
        return frames
    }

    static func videoDamageSpan(frames: [DecodedFrame], window: ClosedRange<Double>,
                                frameInterval: Double) -> (start: Double, end: Double)? {
        var start: Double? = nil
        var end: Double? = nil
        func extend(_ s: Double, _ e: Double) {
            start = min(start ?? s, s)
            end = max(end ?? e, e)
        }
        for (i, frame) in frames.enumerated() {
            if frame.corrupt, window.contains(frame.pts) {
                extend(frame.pts - frameInterval / 2, frame.pts + frameInterval / 2)
            }
            guard i + 1 < frames.count else { continue }
            let d = frames[i + 1].pts - frame.pts
            if d >= frameInterval * 1.8, window.contains(frame.pts + d / 2) {
                extend(frame.pts + frameInterval / 2, frames[i + 1].pts - frameInterval / 2)
            }
        }
        guard let s = start, let e = end else { return nil }
        return (s, e)
    }

    // ADR-0033
    static func resolveZone(candidate: Candidate, span: (start: Double, end: Double)?,
                            decodedFrameCount: Int, containerStart: Double,
                            frameInterval: Double) -> DamageZone? {
        let videoReal = span != nil
            || candidate.hasOpaqueVideoAnomaly
            || (candidate.hasVideoAnomaly && decodedFrameCount == 0)
        if videoReal {
            return nonZeroWidth(DamageZone(
                start: min(candidate.start, span?.start ?? .infinity) - containerStart,
                end: max(candidate.end, span?.end ?? -.infinity) - containerStart,
                affectsVideo: true), frameInterval: frameInterval)
        }
        guard candidate.hasAudioAnomaly else { return nil }
        return nonZeroWidth(DamageZone(start: candidate.start - containerStart,
                                       end: candidate.end - containerStart, affectsVideo: false),
                            frameInterval: frameInterval)
    }

    static func nonZeroWidth(_ zone: DamageZone, frameInterval: Double) -> DamageZone {
        guard zone.end - zone.start < frameInterval else { return zone }
        return DamageZone(start: zone.start, end: zone.start + frameInterval,
                          affectsVideo: zone.affectsVideo)
    }

    static func detectZones(url: URL, scan: FrameIndexer.AllStreamsScan,
                            containerStart: Double,
                            onCandidates: (Int) -> Void = { _ in }) async -> [DamageZone] {
        let index = scan.index
        guard index.count > minIntervals,
              let interval = medianInterval(index.pts),
              let ffmpeg = try? FFTools.ffmpegURL() else { return [] }

        var zones: [DamageZone] = []
        let candidates = clusterCandidates(anomalies(streams: scan.streams))
        onCandidates(candidates.count)
        for candidate in candidates {
            let anchorFrame = index.frameIndex(atOrBeforeTime: candidate.start - 0.5)
            var keyframe = index.keyframeIndex(atOrBefore: anchorFrame) ?? 0
            keyframe = index.keyframeIndex(atOrBefore: max(0, keyframe - 1)) ?? 0
            let seekPts = index.pts[keyframe]
            let windowEnd = candidate.end + tailLookahead
            guard windowEnd > seekPts else { continue }

            let frames = await confirmDecode(
                ffmpeg, url: url, seek: seekPts - containerStart,
                duration: windowEnd - seekPts)
            let absolute = frames.map { DecodedFrame(pts: $0.pts + seekPts, corrupt: $0.corrupt) }
            let local = marginInterval(frames: absolute, candidate: candidate)
                ?? medianInterval(absolute.map(\.pts)) ?? interval
            let span = videoDamageSpan(
                frames: absolute,
                window: (candidate.start - 1.0)...(candidate.end + tailLookahead),
                frameInterval: local)
            if let zone = resolveZone(candidate: candidate, span: span,
                                      decodedFrameCount: absolute.count,
                                      containerStart: containerStart, frameInterval: local) {
                zones.append(zone)
            }
        }

        if let eof = await eofZone(ffmpeg, url: url, index: index,
                                   frameInterval: interval, containerStart: containerStart) {
            if var last = zones.last, eof.start - last.end <= 2.0 {
                last.end = max(last.end, eof.end)
                last.affectsVideo = last.affectsVideo || eof.affectsVideo
                zones[zones.count - 1] = last
            } else {
                zones.append(eof)
            }
        }
        return zones.sorted { $0.start < $1.start }
    }

    private static func eofZone(_ ffmpeg: URL, url: URL, index: FrameIndex,
                                frameInterval: Double, containerStart: Double) async -> DamageZone? {
        guard let lastPts = index.pts.last else { return nil }
        var keyframe = index.keyframeIndex(atOrBefore: index.count - 1) ?? 0
        for _ in 0..<2 { keyframe = index.keyframeIndex(atOrBefore: max(0, keyframe - 1)) ?? 0 }
        let seekPts = index.pts[keyframe]
        guard lastPts > seekPts else { return nil }

        let frames = await confirmDecode(
            ffmpeg, url: url, seek: seekPts - containerStart, duration: nil)
        guard !frames.isEmpty else { return nil }
        let absolute = frames.map { DecodedFrame(pts: $0.pts + seekPts, corrupt: $0.corrupt) }
        let local = medianInterval(absolute.map(\.pts)) ?? frameInterval
        return eofZoneFromDecode(frames: absolute, lastPts: lastPts, seekPts: seekPts,
                                 localInterval: local, containerStart: containerStart)
    }

    // ADR-0033
    static func eofZoneFromDecode(frames: [DecodedFrame], lastPts: Double, seekPts: Double,
                                  localInterval local: Double, containerStart: Double) -> DamageZone? {
        var span: (start: Double, end: Double)? = nil
        for frame in frames where frame.corrupt && frame.pts >= seekPts {
            span = (min(span?.start ?? .infinity, frame.pts - local / 2),
                    max(span?.end ?? -.infinity, frame.pts + local / 2))
        }
        if let lastDecoded = frames.last?.pts, lastDecoded < lastPts - local * 0.75 {
            let missingStart = lastDecoded + local / 2
            span = (min(span?.start ?? missingStart, missingStart),
                    max(span?.end ?? 0, lastPts + local))
        }
        guard let s = span else { return nil }
        return nonZeroWidth(DamageZone(start: s.start - containerStart, end: s.end - containerStart,
                                       affectsVideo: true), frameInterval: local)
    }

    private static func confirmDecode(_ ffmpeg: URL, url: URL, seek: Double,
                                      duration: Double?) async -> [DecodedFrame] {
        var args = ["-v", "info", "-ss", ExportEngine.timeString(max(0, seek))]
        if let duration { args += ["-t", ExportEngine.timeString(duration)] }
        args += ["-i", url.path, "-map", "0:v:0", "-vf", "showinfo", "-f", "null", "-"]
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-confirm-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: dump) }
        guard (try? await ProcessRunner.run(ffmpeg, args, stderrTo: dump)) != nil,
              let stderr = try? String(contentsOf: dump, encoding: .utf8) else { return [] }
        return parseConfirmDecode(stderr: stderr)
    }
}
