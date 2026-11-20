import Foundation

enum ExportPlanner {
    struct ClipInput {
        var clip: Clip
        var url: URL
        var index: FrameIndex
        var containerStart: Double
        var audioSources: [ExportEngine.AudioSource?]
        var audioMixFilters: [String?] = []
    }

    enum VideoTreatment: Equatable {
        case smartRender(segments: [PlannedSegment], encoder: [String])
        case conform(ConformEngine.VideoConform)
    }

    enum PlanPurpose {
        case export
        case repair
    }

    static func videoTreatment(for clip: Clip, target: Clip?, index: FrameIndex,
                               containerStart: Double = 0,
                               purpose: PlanPurpose = .export) throws -> VideoTreatment {
        guard clip.video != nil else {
            throw ExportError.clipNotReady("“\(clip.displayName)” isn’t ready to export yet — no video track was read.")
        }
        if let target, let tv = target.video, let cv = clip.video,
           !MatchEvaluator.matches(clip, target: target) {
            return .conform(ConformEngine.VideoConform(
                sourceVideo: cv, targetVideo: tv,
                damage: (clip.damageZones ?? []).filter(\.affectsVideo)))
        }
        let leadingCounts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: index.keyframeFlags, dts: index.dts)
        let copyCutRoute = FieldCodedSupport.requiresCopyOnlyCuts(
            fieldCoded: clip.fieldCoded, codec: clip.video?.codec)
        let damage: [BoundaryReencodePlanner.DamageSpan]
        if purpose == .export, copyCutRoute {
            damage = []
        } else if let zones = clip.damageZones, !zones.isEmpty,
           let rate = clip.video?.frameRate, ConformEngine.frameRateValue(rate) != nil {
            damage = BoundaryReencodePlanner.damageSpans(
                zones: zones, pts: index.pts, dts: index.dts, containerStart: containerStart)
        } else {
            damage = []
        }
        let segments = BoundaryReencodePlanner.plan(
            leadingCounts: leadingCounts, frameCount: index.count,
            inFrame: clip.inPoint, outFrame: clip.outPoint, damage: damage)
        guard !segments.isEmpty else { throw ExportError.invalidPlan }
        if purpose == .export, copyCutRoute,
           segments.contains(where: { $0.kind == .reEncode }) {
            throw ExportError.fieldCodedPlanNotCopyOnly(clip: clip.displayName)
        }
        let encoder = BoundaryReencodeEngine.reencodeVideoArgs(
            codec: clip.video?.codec,
            profile: clip.video?.profile,
            pixelFormat: clip.video?.pixelFormat,
            fieldOrder: clip.video?.fieldOrder,
            bitrate: clip.video?.bitrate)
        return .smartRender(segments: segments, encoder: encoder)
    }

    static func effectiveTarget(_ target: Clip?, settings: OutputSettings) -> Clip? {
        settings.mode == .separate && settings.rendering == .cutOnly ? nil : target
    }

    static func planItem(for input: ClipInput, target: Clip?,
                         settings: OutputSettings = OutputSettings()) throws -> ExportItem {
        let target = effectiveTarget(target, settings: settings)
        let clip = input.clip
        let index = input.index
        func keptPts(_ frame: Int?) throws -> Double? {
            guard let frame else { return nil }
            guard index.pts.indices.contains(frame) else { throw ExportError.invalidPlan }
            return index.pts[frame]
        }
        let outEndPts = clip.outPoint.flatMap { out in
            index.pts.indices.contains(out + 1) ? index.pts[out + 1] : nil
        }
        let window = ExportEngine.keptWindow(
            inPts: try keptPts(clip.inPoint),
            outPts: try keptPts(clip.outPoint),
            outEndPts: outEndPts,
            firstPts: index.pts.first, lastPts: index.pts.last,
            frameDuration: frameDuration(clip.video?.frameRate),
            containerStart: input.containerStart)
        let trimEnd = truncatedEndingTrim(for: clip, index: index,
                                          containerStart: input.containerStart,
                                          windowStart: window.start)
        switch try videoTreatment(for: clip, target: target, index: index,
                                  containerStart: input.containerStart) {
        case .conform(var conform):
            conform.trimEnd = trimEnd
            conform.crf = settings.conformCrf
            return ExportItem(source: input.url, displayName: clip.displayName,
                              codec: conform.targetVideo.codec,
                              audioStart: window.start, audioEnd: window.end,
                              audioSources: input.audioSources,
                              audioMixFilters: input.audioMixFilters,
                              audioDuration: window.duration,
                              conform: conform, truncatedEndingTrim: trimEnd)
        case .smartRender(let segments, let encoder):
            return ExportItem(source: input.url, displayName: clip.displayName,
                              codec: clip.video?.codec,
                              segments: segments, index: index, encoder: encoder,
                              containerStart: input.containerStart,
                              frameRate: clip.video?.frameRate,
                              sourceDamaged: !(clip.damageZones ?? []).isEmpty,
                              fieldCoded: FieldCodedSupport.requiresCopyOnlyCuts(
                                fieldCoded: clip.fieldCoded, codec: clip.video?.codec),
                              sourceReorderDepth: clip.video?.reorderDepth,
                              audioStart: window.start, audioEnd: window.end,
                              audioSources: input.audioSources,
                              audioMixFilters: input.audioMixFilters,
                              audioDuration: window.duration,
                              truncatedEndingTrim: trimEnd)
        }
    }

    static func reorderDepthWarning(items: [ExportItem], settings: OutputSettings) -> String? {
        guard settings.container == .mkv, settings.mode == .connect, items.count > 1,
              settings.type != .audioOnly, let first = items.first else { return nil }
        let joinDepth = ExportEngine.joinReorderDepth(items: items)
        let declared = ExportEngine.firstPieceIsEncoded(first)
            ? min(joinDepth, EncoderSelection.deepestEncodableReorderDepth)
            : (first.sourceReorderDepth ?? 1)
        guard declared < joinDepth,
              let deeper = items.first(where: {
                  $0.conform == nil && ($0.sourceReorderDepth ?? 1) > declared
                      && $0.segments.contains(where: { $0.kind == .copy })
              }) else { return nil }
        return "“\(deeper.displayName)” shuffles its frame order more deeply than "
            + "“\(first.displayName)”, and an MKV can only record one such order per file —"
            + " other tools may read this join's timestamps wrong. Put “\(deeper.displayName)”"
            + " first, or export as MP4 or TS, which record it per frame."
    }

    static func truncatedEndingTrim(zones: [DamageZone]?, windowStart: Double?, fileEnd: Double?,
                                    reachesFileEnd: Bool, frameInterval: Double?) -> Double? {
        guard reachesFileEnd, let fileEnd else { return nil }
        let start = windowStart ?? 0
        let margin = frameInterval ?? (1.0 / 25)
        return (zones ?? [])
            .filter { $0.affectsVideo && $0.end >= fileEnd - margin && $0.start > start }
            .map(\.start).min()
    }

    static func truncatedEndingTrim(for clip: Clip, index: FrameIndex,
                                    containerStart: Double, windowStart: Double?) -> Double? {
        let interval = frameDuration(clip.video?.frameRate)
        let reachesFileEnd = clip.outPoint.map { $0 >= index.count - 1 } ?? true
        return truncatedEndingTrim(zones: clip.damageZones, windowStart: windowStart,
                                   fileEnd: fileEnd(index: index, frameRate: clip.video?.frameRate,
                                                    containerStart: containerStart),
                                   reachesFileEnd: reachesFileEnd, frameInterval: interval)
    }

    static func fileEnd(index: FrameIndex, frameRate: String?, containerStart: Double) -> Double? {
        let interval = frameDuration(frameRate)
        return index.pts.last.map { $0 + (interval ?? 0) - containerStart }
    }

    static func repairReport(clipName: String, zones: [DamageZone]?,
                             windowStart: Double?, windowEnd: Double?,
                             trimEnd: Double? = nil, frameInterval: Double? = nil) -> String? {
        let slack = frameInterval ?? (1.0 / 25)
        let repaired = (zones ?? []).filter { zone in
            zone.affectsVideo
                && zone.end > (windowStart ?? 0)
                && (windowEnd.map { zone.start < $0 + slack } ?? true)
        }
        let hasTruncatedEnding = trimEnd != nil
        let interior = trimEnd.map { t in repaired.filter { $0.start < t } } ?? repaired
        guard !interior.isEmpty || hasTruncatedEnding else { return nil }
        let shown = interior.prefix(6).map { formattedClipTime($0.start) }
        let times = shown.joined(separator: ", ") + (interior.count > 6 ? ", …" : "")
        let ending = hasTruncatedEnding ? " and a truncated ending" : ""
        switch interior.count {
        case 0 where hasTruncatedEnding:
            return "Repaired a truncated ending in “\(clipName)”."
        case 1:
            return "Repaired a damage zone in “\(clipName)” at \(times)\(ending)."
        default:
            return "Repaired \(interior.count) damage zones in “\(clipName)” at \(times)\(ending)."
        }
    }

    static func formattedClipTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    struct CopyShare: Equatable {
        var copiedSeconds: Double
        var totalSeconds: Double
        var copiedFraction: Double { totalSeconds > 0 ? copiedSeconds / totalSeconds : 0 }
    }

    static func copyShare(for clip: Clip, target: Clip?, settings: OutputSettings,
                          index: FrameIndex, containerStart: Double = 0) -> CopyShare? {
        guard index.count > 0 else { return nil }
        let target = effectiveTarget(target, settings: settings)
        guard let treatment = try? videoTreatment(for: clip, target: target, index: index,
                                                  containerStart: containerStart) else {
            return nil
        }
        switch treatment {
        case .conform:
            let inStart = clip.inPoint ?? 0
            let outEx = clip.outPoint.map { $0 + 1 } ?? index.count
            guard outEx > inStart else { return nil }
            return CopyShare(copiedSeconds: 0, totalSeconds: duration(of: inStart..<outEx, index: index))
        case .smartRender(let segments, _):
            return copyShare(segments: segments, index: index)
        }
    }

    static func copyShare(segments: [PlannedSegment], index: FrameIndex) -> CopyShare {
        CopyShare(copiedSeconds: segments.filter { $0.kind == .copy }
                    .reduce(0.0) { $0 + duration(of: $1.range, index: index) },
                  totalSeconds: segments.reduce(0.0) { $0 + duration(of: $1.range, index: index) })
    }

    static func duration(of range: Range<Int>, index: FrameIndex) -> Double {
        let pts = index.pts
        guard range.lowerBound >= 0, range.lowerBound < range.upperBound,
              range.lowerBound < pts.count else { return 0 }
        let upper = min(range.upperBound, pts.count)
        let start = pts[range.lowerBound]
        let end: Double
        if upper < pts.count {
            end = pts[upper]
        } else {
            let last = pts[pts.count - 1]
            end = last + (pts.count > 1 ? max(0, last - pts[pts.count - 2]) : 0)
        }
        return max(0, end - start)
    }

    static func reencodeDominanceWarning(shares: [CopyShare]) -> String? {
        let total = shares.reduce(0.0) { $0 + $1.totalSeconds }
        let copied = shares.reduce(0.0) { $0 + $1.copiedSeconds }
        let reencoded = total - copied
        guard total > 0, reencoded / total > 0.5 else { return nil }
        return "~\(Int(reencoded.rounded())) s of \(Int(total.rounded())) s will be re-encoded"
            + " — little of this export can be stream-copied untouched."
    }

    static func frameDuration(_ frameRate: String?) -> Double? {
        let parts = (frameRate ?? "").split(separator: "/")
        guard parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]),
              num > 0, den > 0 else { return nil }
        return den / num
    }
}
