import Foundation

/// The pure planning behind the document's export entry point: per clip, the
/// smart-render-vs-conform verdict (ADR-0005 / ADR-0011), the boundary re-encode
/// segment plan (ADR-0009), the kept window every audio leg is forced to (ADR-0014),
/// and the assembled `ExportItem` the engine consumes. Clips, the target clip, frame
/// indexes, and container start times go in; export items come out — no file IO, so
/// the verdict matrix is unit-testable without constructing a document.
enum ExportPlanner {
    /// Everything the planner needs to know about one clip, gathered by the caller
    /// (the file IO — URL resolution, frame indexing, the start-time probe, and the
    /// audio source resolution — is done by then).
    struct ClipInput {
        var clip: Clip
        var url: URL
        var index: FrameIndex
        var containerStart: Double
        var audioSources: [ExportEngine.AudioSource?]
        /// Per-track channel-mix filters (ADR-0019), resolved alongside `audioSources`
        /// by `AudioSourceResolver.resolveMixFilters`; nil legs carry no mix.
        var audioMixFilters: [String?] = []
    }

    /// How one clip's video reaches the output (ADR-0011) — exactly one of the two,
    /// by construction. A clip is *either* smart-rendered (the keyframe-bounded middle
    /// stream-copied, the partial-GOP edges re-encoded with source-matched args —
    /// ADR-0009) *or* conformed (its whole kept range re-encoded to the target spec);
    /// the old both/neither states a caller could assemble are unrepresentable here.
    enum VideoTreatment: Equatable {
        case smartRender(segments: [PlannedSegment], encoder: [String])
        case conform(ConformEngine.VideoConform)
    }

    /// One clip's video treatment. A clip that doesn't match the target is conformed:
    /// a full re-encode of its kept range to the target spec (ADR-0011). A matching
    /// clip — or any clip when there is no target video spec or no probed clip video
    /// to compare — is smart-rendered. Audio never enters the verdict — every leg is
    /// conformed to its output track's format inside the rebuild chain (ADR-0014).
    /// On the smart-render path, throws `ExportError.invalidPlan` when the kept range
    /// collapses to nothing.
    ///
    /// `containerStart` maps the clip's recorded damage zones (issue #45) onto index
    /// frames — each zone in range forces a repaired re-encode segment (issue #47).
    /// A clip with no zones plans byte-identically to before repair existed.
    static func videoTreatment(for clip: Clip, target: Clip?, index: FrameIndex,
                               containerStart: Double = 0) throws -> VideoTreatment {
        // No probed video means the clip is still importing (or its import failed):
        // the smart-render path below reads `clip.video?.codec` and would default the
        // encoder to libx264, silently re-encoding an HEVC/MPEG-2 source wrong (issue
        // #78). The document gates the Export button and `export()` on import state;
        // this refuses the plan itself, so no code path reaches encoder selection with
        // `video == nil` — belt-and-braces even if the gate is bypassed.
        guard clip.video != nil else {
            throw ExportError.clipNotReady("“\(clip.displayName)” isn’t ready to export yet — no video track was read.")
        }
        if let target, let tv = target.video, let cv = clip.video,
           !MatchEvaluator.matches(clip, target: target) {
            // The conform chain drops the clip's damaged spans before its fps fill
            // (issue #48); a clean clip's chain is unchanged.
            return .conform(ConformEngine.VideoConform(
                sourceVideo: cv, targetVideo: tv,
                damage: (clip.damageZones ?? []).filter(\.affectsVideo)))
        }
        let leadingCounts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: index.keyframeFlags, dts: index.dts)
        // Repair needs the source rate (the fps fill and slot budget); a clip whose
        // rate doesn't parse plans as before — the verify gates still police the output.
        let damage: [BoundaryReencodePlanner.DamageSpan]
        if let zones = clip.damageZones, !zones.isEmpty,
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
        // Re-encode args matched to the source so the edges concat cleanly with the
        // copied middle (ADR-0009).
        let encoder = BoundaryReencodeEngine.reencodeVideoArgs(
            codec: clip.video?.codec,
            profile: clip.video?.profile,
            pixelFormat: clip.video?.pixelFormat,
            fieldOrder: clip.video?.fieldOrder)
        return .smartRender(segments: segments, encoder: encoder)
    }

    /// The target the verdict consults. Cut-only severs it (ADR-0018): in separate mode
    /// with the cut-only rendering choice every clip smart-renders against itself —
    /// `videoTreatment` with no target never constructs `.conform`, and the boundary
    /// re-encode args already derive from the clip's own probed properties (ADR-0009).
    /// Every other mode×rendering combination consults the project's target unchanged.
    static func effectiveTarget(_ target: Clip?, settings: OutputSettings) -> Clip? {
        settings.mode == .separate && settings.rendering == .cutOnly ? nil : target
    }

    /// Plans one clip's export item: the video treatment plus the kept range as a seek
    /// window. A `nil` in/out point means that end is the clip boundary (no cut there),
    /// so audio — and a conformed clip's video — runs to the file's start/end too. The
    /// window subtracts the container's start_time (issue #3: input `-ss` is measured
    /// from it, not absolute pts — passing pts cut every leg 0.24 s late on the MPEG-PS
    /// clip), and its duration is the kept *video* span every audio leg is forced to,
    /// so the output tracks stay sample-aligned at joins (ADR-0014).
    static func planItem(for input: ClipInput, target: Clip?,
                         settings: OutputSettings = OutputSettings()) throws -> ExportItem {
        let target = effectiveTarget(target, settings: settings)
        let clip = input.clip
        let index = input.index
        // Belt-and-braces: a stored in/out that outran a re-imported (shorter) index
        // would trap the raw `index.pts[$0]` subscript below (issue #74). The relink
        // re-import already resets out-of-range points, but no plan path may ever trap —
        // refuse with `invalidPlan` instead.
        func keptPts(_ frame: Int?) throws -> Double? {
            guard let frame else { return nil }
            guard index.pts.indices.contains(frame) else { throw ExportError.invalidPlan }
            return index.pts[frame]
        }
        // The frame after the out point (`pts[out+1]`), when it exists: the out frame's
        // display end, where the kept video span reaches (`clipSpan`, #75). nil for an
        // open out point or when the out is the last frame (the file-end fallback in
        // `keptWindow` then uses one frame beyond the out pts).
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
        switch try videoTreatment(for: clip, target: target, index: index,
                                  containerStart: input.containerStart) {
        case .conform(let conform):
            return ExportItem(source: input.url, displayName: clip.displayName,
                              codec: conform.targetVideo.codec,
                              audioStart: window.start, audioEnd: window.end,
                              audioSources: input.audioSources,
                              audioMixFilters: input.audioMixFilters,
                              audioDuration: window.duration,
                              conform: conform)
        case .smartRender(let segments, let encoder):
            return ExportItem(source: input.url, displayName: clip.displayName,
                              codec: clip.video?.codec,
                              segments: segments, index: index, encoder: encoder,
                              containerStart: input.containerStart,
                              frameRate: clip.video?.frameRate,
                              sourceDamaged: !(clip.damageZones ?? []).isEmpty,
                              audioStart: window.start, audioEnd: window.end,
                              audioSources: input.audioSources,
                              audioMixFilters: input.audioMixFilters,
                              audioDuration: window.duration)
        }
    }

    // MARK: - Repair report (#47)

    /// The export-completion line reporting what one clip's export repaired: the
    /// video-affecting zones inside the kept window — exactly the zones the plan
    /// forced into repaired re-encode segments (audio-only gaps are silence-filled by
    /// every leg already, issue #44, and stay out of the count). Positions are clip
    /// time, formatted like the source row's damage line, capped at six. `nil` when
    /// nothing was repaired: no zones, none in the window, or video wasn't exported.
    static func repairReport(clipName: String, zones: [DamageZone]?,
                             windowStart: Double?, windowEnd: Double?) -> String? {
        let repaired = (zones ?? []).filter { zone in
            zone.affectsVideo
                && zone.end > (windowStart ?? 0)
                && (windowEnd.map { zone.start < $0 } ?? true)
        }
        guard !repaired.isEmpty else { return nil }
        let shown = repaired.prefix(6).map { formattedClipTime($0.start) }
        let times = shown.joined(separator: ", ") + (repaired.count > 6 ? ", …" : "")
        return repaired.count == 1
            ? "Repaired a damage zone in “\(clipName)” at \(times)."
            : "Repaired \(repaired.count) damage zones in “\(clipName)” at \(times)."
    }

    /// h:mm:ss (or m:ss under an hour), rounded down — the cut-editor's jump popover
    /// accepts these directly. Shared with the source row's damage line so the report
    /// and the row can't disagree about a zone's position.
    static func formattedClipTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - Copy/re-encode share (issue #15)

    /// How much of a clip's kept range the plan stream-copies vs re-encodes, in seconds
    /// of source presentation time — duration-weighted through the frame index's pts,
    /// never segment-count-weighted (GOPs are not uniform).
    struct CopyShare: Equatable {
        var copiedSeconds: Double
        var totalSeconds: Double
        /// 0…1; 0 when the total is empty (nothing to weight).
        var copiedFraction: Double { totalSeconds > 0 ? copiedSeconds / totalSeconds : 0 }
    }

    /// The clip's copy/re-encode split, computed *before* export from the same verdict and
    /// planner the export itself uses (`videoTreatment` — never a second planning path).
    /// Pure arithmetic over the cached frame index: no media I/O, so the UI can recompute
    /// it on every cut/target/settings change. A conformed clip is a full re-encode of its
    /// kept window; a smart-rendered clip maps each planned segment through the pts. Nil
    /// when no plan exists (empty kept range).
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
            let copied = segments.filter { $0.kind == .copy }
                .reduce(0.0) { $0 + duration(of: $1.range, index: index) }
            let total = segments.reduce(0.0) { $0 + duration(of: $1.range, index: index) }
            return CopyShare(copiedSeconds: copied, totalSeconds: total)
        }
    }

    /// A presentation-frame range's duration in seconds, read off the index pts (so
    /// non-uniform GOP/frame spacing weighs correctly). A range reaching the file end has
    /// no next pts to subtract against; the last frame contributes its predecessor's delta.
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

    /// The Output view's prominent warning when re-encode dominates the export — more than
    /// half the output duration (issue #15). Below the threshold returns nil: closed-GOP
    /// sources re-encode only boundary slivers and the warning would be noise. Cause-free
    /// wording: a dominant re-encode can be sparse clean cut points (open GOP) *or*
    /// conform-routed clips.
    static func reencodeDominanceWarning(shares: [CopyShare]) -> String? {
        let total = shares.reduce(0.0) { $0 + $1.totalSeconds }
        let copied = shares.reduce(0.0) { $0 + $1.copiedSeconds }
        let reencoded = total - copied
        guard total > 0, reencoded / total > 0.5 else { return nil }
        return "~\(Int(reencoded.rounded())) s of \(Int(total.rounded())) s will be re-encoded"
            + " — little of this export can be stream-copied untouched."
    }

    /// One frame's duration in seconds from an ffprobe rational rate ("25/1" → 0.04);
    /// nil when the rate is missing or malformed.
    static func frameDuration(_ frameRate: String?) -> Double? {
        let parts = (frameRate ?? "").split(separator: "/")
        guard parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]),
              num > 0, den > 0 else { return nil }
        return den / num
    }
}
