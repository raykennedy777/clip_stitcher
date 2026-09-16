import Foundation

/// Milestone 3 conform executor (ADR-0011): fully re-encodes a non-matching clip's kept
/// range so that, re-imported, it matches the target clip on every `MatchEvaluator`
/// dimension. The argument builders are pure so the exact command shape can be unit-tested;
/// the recipes were validated against the real H.264/HEVC/MPEG-2 footage in the shell.
enum ConformEngine {
    /// The probed video specs a conformed clip is transformed between: its own source spec and
    /// the target clip's. Carried on an `ExportItem` to mark it for conform (ADR-0011).
    /// `damage` is the clip's video-affecting damage zones (issue #48): the conform's
    /// full re-encode already fills timeline holes (its `fps` stage), but it would bake
    /// the decoder's glitched frames into clean output — the chain drops each zone's
    /// span so the held frame is the last *good* one. Empty for a clean clip, whose
    /// filter chain stays identical to before repair existed.
    struct VideoConform: Equatable {
        var sourceVideo: VideoProperties
        var targetVideo: VideoProperties
        var damage: [DamageZone] = []
        /// The point the kept range is trimmed to for a **truncated ending** (issue #79),
        /// or `nil` when the window has none — the single truncated-ending classification,
        /// decided once in `ExportPlanner` where the clip, its window, and the file end all
        /// coexist (`ExportPlanner.truncatedEndingTrim`). A video zone reaching the *file's*
        /// end is repaired by trimming to the last complete frame rather than the interior
        /// drop+fps-fill, so the conform's input read stops here. `nil` for a clean clip or
        /// an interior out point keeps the command byte-identical to before repair existed —
        /// the conform executor never re-derives this from raw zones with its own margin.
        var trimEnd: Double? = nil
        /// The CRF this conform encodes at (`OutputSettings.conformCrf`, stamped by
        /// `ExportPlanner.planItem` like `trimEnd`) — nil keeps the encoder default,
        /// byte-identical to before the knob existed. x264/x265 only; an MPEG-2
        /// target ignores it (no CRF rate control).
        var crf: Int? = nil
    }

    /// ffmpeg video filter-chain + encoder args that transform `source` → `target`. The
    /// chain runs deinterlace (if any) → scale → pad (only on a display-aspect mismatch) →
    /// setsar → format → color conversion toward a tagged target (issue #35) → damage-zone
    /// select (issue #48) → fps/interlace → scan direction (issue #117); the encoder then pins
    /// the target codec, profile, level, interlace flags, color range, and — for a fully
    /// color-tagged target — the primaries/transfer/matrix VUI triple.
    ///
    /// `damage`/`windowStart`/`windowEnd` repair a damaged clip (issue #48): each zone in
    /// the kept window becomes a `select` drop before the fps stage, whose fill then
    /// repeats the last good frame across it. Zone times and the window are both
    /// container-start-relative, the same base the conform's input seek uses, so the
    /// select windows are expressed relative to the seek (validated on all three formats
    /// × three containers in the shell, exact counts and clean decodes).
    ///
    /// `reorderDepth` is the depth this piece's decode order is encoded at — the one every
    /// piece of its join must agree on (ADR-0026); the shallow default keeps the
    /// pyramid-free command this engine has always produced.
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

    /// The time-window select dropping each damage zone inside the kept window
    /// (issue #48), or nil when nothing needs dropping. Windows get a quarter-frame
    /// margin against float jitter and are clamped so the window's first source frame
    /// always survives — the fps fill needs a frame to hold, and a glitched held frame
    /// beats a shifted timeline when damage touches the window head.
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

    /// The audio filter that conforms a clip's audio to the target's sample rate and channel
    /// layout before the sample-level concat (ADR-0011). Applied per conforming leg in the
    /// audio rebuild; matching clips need no filter. Idempotent when already on target.
    ///
    /// `fillGaps` makes the leading resample defensive against damaged sources (issue #44):
    /// `async=1` fills timestamp gaps with silence *in place* instead of closing them up
    /// (a closed gap plays everything after it early — ~1.8 s of accumulated A/V drift on
    /// a real broadcast capture), and `first_pts=0` anchors the stream so a window that
    /// *starts* inside a dead zone is silence-led rather than shortened. On a clean source
    /// the options are a proven no-op: the de-risked legs are byte-identical with and
    /// without them on all three formats (issue #43). The export rebuild turns this on;
    /// the preview's legs keep the plain conform.
    static func audioFilter(sampleRate: Int, channels: Int, fillGaps: Bool = false) -> String {
        let resample = fillGaps ? "aresample=\(sampleRate):async=1:first_pts=0"
                                : "aresample=\(sampleRate)"
        return resample + ",aformat=channel_layouts=\(channelLayout(channels))"
    }

    /// The channel-mix filter for one audio leg (ADR-0019), inserted **before** the
    /// per-leg `audioFilter` conform on every surface (export rebuild, cut-editor,
    /// output preview — one builder so the three can't drift). nil when the mix is a
    /// no-op for the source — then the leg stays byte-identical to today's. The mix
    /// works on the source's normal stereo listening experience: a surround source is
    /// first folded to stereo (ffmpeg's standard fold-down — the same one `-ac 2`
    /// applies), then Left/Right/Mono shape that stereo image. The conform after it
    /// carries the result into the output track's fixed layout. De-risked in the shell
    /// on MPEG-2/H.264/HEVC in TS/MKV/MP4 with a synthesized 5.1 source (2026-06):
    /// sample counts and track layouts are untouched by every recipe.
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
    /// in point — `start`/`end` are input-seek seconds (`ExportEngine.keptWindow`), measured
    /// from the container's start_time — and a read duration (the same window the audio
    /// uses, so a conformed clip's video and audio stay aligned), then the
    /// source→target transform. Audio is dropped; the rebuilt track is muxed in later. An
    /// open start/end omits the corresponding seek flag (read from file start / to file end).
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
        // The conformed piece carries its own parameter sets in-band (issue #113). A conform
        // is re-encoded to the *target's* spec, but it is still a distinct encoder run from
        // every other piece in the join — and the join's container holds only the first
        // piece's header — so without this the Fill between two stream-copied clips decoded
        // against the copies' SPS/PPS and came out as garbage at an exactly-correct frame
        // count (`ExportEngine.parameterSetRepeatFilter`).
        args += ["-bsf:v", ExportEngine.parameterSetRepeatFilter]
        // The export-wide MP4 pin (issue #24): without it the encoder-default 1/12800
        // track collapses next to a copy piece at the cross-clip concat.
        if let trackTimescale { args += ["-video_track_timescale", String(trackTimescale)] }
        args += ["-an", output.path]
        return args
    }

    // MARK: - Orchestration

    /// Conforms one clip's kept range into a single video piece in `work` and returns it. The
    /// piece is a from-scratch re-encode to the target spec (`conformArguments`), then it
    /// **self-verifies before it ships** (ADR-0011): re-probed it must match the target's
    /// video spec, and a full `-xerror` decode must pass — otherwise the export fails loudly
    /// naming the offending dimension, never shipping a near-miss. Audio is rebuilt separately.
    /// `onProgress` reports 0…1 across the re-encode run (issue #9) — ffmpeg's out_time
    /// against the kept window's duration, which a conform preserves (the fps change
    /// trades frame count, not length). The closing verify isn't instrumented — the bar
    /// holds at the clip's top edge while it runs.
    static func produceConformedPiece(
        _ ffmpeg: URL, source: URL, conform: VideoConform,
        start: Double?, end: Double?, work: URL, ext: String, clipIndex: Int,
        displayName: String = "", trackTimescale: Int? = nil, reorderDepth: Int = 1,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let piece = work.appendingPathComponent("c\(clipIndex)_conform.\(ext)")
        // The kept window's duration — an open end reads to the source's end, so it is
        // probed up front. It drives both the within-run progress mapping and the
        // frame-count verification target (`nil` skips both rather than guess blind).
        let windowEnd: Double?
        if let end {
            windowEnd = end
        } else {
            windowEnd = try await MediaProbe.probe(url: source).duration
        }
        // A truncated ending — a video zone reaching the *file's* end — is repaired by
        // trimming to the last complete frame, not fps-filled (CONTEXT.md "Repair"): shorten
        // the input read to the zone's start so the piece ends there. The classification is
        // decided once upstream (`ExportPlanner.truncatedEndingTrim`) and carried on the
        // conform — never re-derived here from raw zones — so the executor and the completion
        // report can't disagree. `nil` for a clean or interior-only clip (or an interior out
        // point) keeps the window and the command byte-identical to before.
        let trimEnd = conform.trimEnd
        let effectiveEnd = trimEnd ?? end
        let windowDuration = (trimEnd ?? windowEnd).map { $0 - (start ?? 0) }
        let args = conformArguments(source: source, start: start, end: effectiveEnd,
                                    sourceVideo: conform.sourceVideo, targetVideo: conform.targetVideo,
                                    output: piece,
                                    trackTimescale: ext.lowercased() == "mp4" ? trackTimescale : nil,
                                    damage: conform.damage, crf: conform.crf,
                                    reorderDepth: reorderDepth)
        let parser = ProgressParser()
        let result = try await ProcessRunner.run(ffmpeg, ExportProgress.progressArguments(args)) { chunk in
            if let t = parser.feed(chunk) {
                onProgress(ExportProgress.runFraction(outTime: t, expectedSeconds: windowDuration))
            }
        }
        guard result.status == 0 else {
            throw ExportError.conformFailed(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
        guard FileManager.default.fileExists(atPath: piece.path) else { throw ExportError.missingSegment }
        let expected = windowDuration.flatMap {
            expectedFrameCount(windowDuration: $0, targetFrameRate: conform.targetVideo.frameRate)
        }
        try await verifyConformed(ffmpeg, piece, target: conform.targetVideo, expectedFrames: expected,
                                  shortfallAllowance: eofShortfallAllowance(
                                      trimEnd: trimEnd, fileEnd: windowEnd,
                                      targetFrameRate: conform.targetVideo.frameRate),
                                  requireSilentDecode: conform.damage.isEmpty,
                                  at: VerificationLocation(
                                      clipIndex: clipIndex, displayName: displayName,
                                      piece: piece.lastPathComponent, conformed: true))
        return piece
    }

    /// The frame count a conformed piece should have for a kept window of `windowDuration`
    /// seconds re-encoded to `targetFrameRate`: `duration × fps`, rounded. M2's exact
    /// frame-count assertion is relaxed to this (±1) for conformed pieces because fps
    /// conversion legitimately changes the count (ADR-0011). `nil` when the rate is unparseable.
    static func expectedFrameCount(windowDuration: Double, targetFrameRate: String) -> Int? {
        guard windowDuration > 0, let fps = frameRateValue(targetFrameRate) else { return nil }
        return Int((windowDuration * fps).rounded())
    }

    /// How far below `duration × fps` a conformed piece may legitimately fall (issue #48).
    /// Non-zero only for a genuine **truncated ending** (`trimEnd` set — the single
    /// classification from `ExportPlanner.truncatedEndingTrim`, never re-derived here): the
    /// input read stops at `trimEnd`, so the piece drops the trailing damaged span
    /// `[trimEnd, fileEnd)`, and the container's reported end can itself overshoot the last
    /// decodable frame (the 1844's TS headers claim ~0.2 s past the truncated final frame).
    /// The allowance is that dropped span in frames, plus one for the trim-boundary frame that
    /// may not decode. 0 when there is no truncated ending — keeping the ±1 gate exact for
    /// every clean or interior-only clip, so a spurious near-interior-zone relaxation (the
    /// old 1.0 s, no-file-end-gate behavior) can never mask a real shortfall.
    static func eofShortfallAllowance(trimEnd: Double?, fileEnd: Double?,
                                      targetFrameRate: String) -> Int {
        guard let trimEnd, let fileEnd, let fps = frameRateValue(targetFrameRate) else { return 0 }
        return max(0, Int(((fileEnd - trimEnd) * fps).rounded()) + 1)
    }

    /// Verifies a conformed piece against the acceptance bar (ADR-0011): its re-probed video
    /// must match the target spec, its frame count must be within ±1 of the kept window at the
    /// target rate (the relaxed M2 assertion — plus the EOF-damage shortfall allowance,
    /// issue #48), and a full decode must succeed.
    ///
    /// "Succeed" means **silently** unless the source is damaged (`requireSilentDecode`, issue
    /// #113): a decoder conceals what it cannot parse and still exits 0, so the status alone
    /// would pass a piece whose every frame is colour garbage. A repair conform is exempt — its
    /// damaged source legitimately prints a per-frame flood.
    private static func verifyConformed(
        _ ffmpeg: URL, _ piece: URL, target: VideoProperties, expectedFrames: Int?,
        shortfallAllowance: Int = 0, requireSilentDecode: Bool = true,
        at location: VerificationLocation
    ) async throws {
        var probed = try await MediaProbe.probe(url: piece).video
        // The stream-level `field_order` carries no direction outside Matroska — an
        // interlaced H.264 stream in MP4 or MPEG-TS probes `tt` whichever field leads — and
        // Matroska's tag only says what ffmpeg's front end believed, not what the encoder
        // coded (libx265 ignores the interlace flags). The coded frames are authoritative,
        // so the scan the gate compares is read off them (issue #119).
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
        // A conformed clip is a single re-encode at the target frame rate, so its timestamps
        // should be uniformly spaced; this catches the duplicate PTS that the B-pyramid/MKV
        // stream-copy collapse once produced (ADR-0011) before the clip ships.
        let pts = try await FrameIndexer.buildIndex(url: piece).pts
        if let reason = ExportEngine.timestampDefect(pts: pts) {
            throw ExportError.verificationFailed(location.message(
                "The conformed clip has irregular timestamps: \(reason)"))
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
        if MatchEvaluator.scanDirection(g.fieldOrder) != MatchEvaluator.scanDirection(want.fieldOrder) {
            diffs.append("scan \(g.fieldOrder ?? "?")≠\(want.fieldOrder ?? "?")")
        }
        if g.sampleAspectRatio != want.sampleAspectRatio {
            diffs.append("sar \(g.sampleAspectRatio ?? "?")≠\(want.sampleAspectRatio ?? "?")")
        }
        // Only a color dimension the target actually specifies counts as a miss — an unspecified
        // target imposes no color requirement (mirrors MatchEvaluator.conformedVideoMatches).
        if !MatchEvaluator.colorSatisfies(g.colorPrimaries, target: want.colorPrimaries)
            || !MatchEvaluator.colorSatisfies(g.colorTransfer, target: want.colorTransfer)
            || !MatchEvaluator.colorSatisfies(g.colorSpace, target: want.colorSpace)
            || !MatchEvaluator.colorSatisfies(g.colorRange, target: want.colorRange) {
            diffs.append("color")
        }
        return diffs.isEmpty ? "video stream differs" : diffs.joined(separator: ", ")
    }

    // MARK: - Filter chain

    private static func filterChain(source: VideoProperties, target: VideoProperties,
                                    repair: String? = nil) -> [String] {
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

        // Color conversion toward a tagged target (issue #35) sits after `format=` — the
        // `colorspace` filter needs one of its supported pixel formats — and before the
        // fps/interlace tail, so it always runs on progressive frames.
        if let stage = colorStage(source: source, target: target) {
            filters.append(stage)
        }

        // Damage-zone drop (issue #48) immediately before the fps stage, whose fill
        // then repeats the last good frame across each dropped span.
        if let repair { filters.append(repair) }

        // Frame-rate / scan tail. Interlacing a progressive source needs the field-rate
        // (2× the target frame rate) feeding the interlace filter, which halves it back.
        if tgtInterlaced && !srcInterlaced {
            filters.append("fps=\(fpsToken(target.frameRate, double: true))")
            filters.append("interlace=scan=\(topFieldFirst(target.fieldOrder) ? "tff" : "bff")")
        } else {
            filters.append("fps=\(fpsToken(target.frameRate, double: false))")
        }

        // Strip tail. When the target carries no color metadata (an untagged SD source like the
        // SATRip H.264), a fully-tagged source (e.g. bt709 HD) would otherwise propagate its VUI
        // into the output, so the conformed clip would be rendered as bt709 next to the untagged
        // target and the join would visibly colour-shift. `setparams` resets the frames to
        // unspecified so the conformed clip plays back under the same default as the target, keeping
        // the seam seamless (ADR-0011). It can't drop everything — libx264 + Matroska still signal
        // limited `tv` range — but that residual tag matches the target's default and is accepted by
        // verifyConformed (conformedVideoMatches ignores colour the target leaves unspecified).
        // Conversion toward a *tagged* target is `colorStage` above (issue #35).
        if targetIsUntagged(target) {
            filters.append("setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown:range=unknown")
        }

        // Scan-direction tail (issue #117). An interlaced *source* keeps its frames through
        // the chain, so nothing above has set which field leads; the encoder used to pin it
        // with `-top`, which ffmpeg 9 removed as an encoding option. `setparams` sets it on
        // the frames instead, and goes last so no later filter can reset it. A **progressive**
        // source is already served by the `interlace=scan=…` filter above. MPEG-2 and H.264
        // only: HEVC is assumed never interlaced (ADR-0011, issue #119).
        if tgtInterlaced, srcInterlaced, BoundaryReencodeEngine.interlaceCapable(target.codec) {
            filters.append(BoundaryReencodeEngine.fieldOrderFilter(target.fieldOrder)
                ?? BoundaryReencodeEngine.topFirstScanFilter)
        }
        return filters
    }

    /// Whether the target declares no color metadata at all — primaries, transfer, matrix, and
    /// range all absent (an untagged source probes every field as "unknown"). Such a target is
    /// matched by stripping the conformed output's tags, not by converting toward a color space.
    private static func targetIsUntagged(_ t: VideoProperties) -> Bool {
        t.colorPrimaries == nil && t.colorTransfer == nil && t.colorSpace == nil && t.colorRange == nil
    }

    // MARK: - Color conversion toward a tagged target (issue #35)

    /// One complete color description — the primaries/transfer/matrix triple plus range — in
    /// ffprobe token spelling. A conversion can only run between two complete specs, so the
    /// builders below resolve every field (probed, else assumed) before any filter is written.
    struct ColorSpec: Equatable {
        var primaries: String
        var transfer: String
        var matrix: String
        var range: String
    }

    /// The target's color spec when it is fully tagged — all three triple fields probed (range
    /// defaults to limited `tv`, broadcast's universal default). A target tagged on only some
    /// triple fields stays nil: a converter cannot aim at a partial spec, so such a target keeps
    /// the pre-#35 behavior (no conversion; verifyConformed still flags the specified fields).
    static func targetColorSpec(_ t: VideoProperties) -> ColorSpec? {
        guard let p = t.colorPrimaries, let tr = t.colorTransfer, let m = t.colorSpace else { return nil }
        return ColorSpec(primaries: p, transfer: tr, matrix: m, range: t.colorRange ?? "tv")
    }

    /// The industry-standard assumption for an untagged source (issue #35): SD (≤ 576 active
    /// lines) is BT.601 — the 625-line variant for the 25/50 fps family, the 525-line variant
    /// for 30000/1001-family rates — and anything taller is BT.709. BT.601's transfer curve is
    /// ffprobe's `smpte170m` for both variants (numerically the same curve as bt709).
    static func assumedColorTriple(height: Int, frameRate: String) -> (primaries: String, transfer: String, matrix: String) {
        guard height <= 576 else { return ("bt709", "bt709", "bt709") }
        let den = frameRate.split(separator: "/").compactMap { Int($0) }.last
        return den == 1001
            ? ("smpte170m", "smpte170m", "smpte170m")
            : ("bt470bg", "smpte170m", "bt470bg")
    }

    /// The source's color spec a conversion reads from: each probed field as-is, each missing
    /// field filled from the `assumedColorTriple` heuristic. `assumed` reports whether any
    /// field was filled — that's when the export surfaces the assumption to the user.
    static func effectiveInputColor(_ s: VideoProperties) -> (spec: ColorSpec, assumed: Bool) {
        let fallback = assumedColorTriple(height: s.height, frameRate: s.frameRate)
        let assumed = s.colorPrimaries == nil || s.colorTransfer == nil || s.colorSpace == nil
        let spec = ColorSpec(primaries: s.colorPrimaries ?? fallback.primaries,
                             transfer: s.colorTransfer ?? fallback.transfer,
                             matrix: s.colorSpace ?? fallback.matrix,
                             range: s.colorRange ?? "tv")
        return (spec, assumed)
    }

    /// The color filter for a tagged target, or nil when none is needed. Three cases (all
    /// shell-proven, issue #35):
    /// - input spec ≠ target spec → a real `colorspace` conversion with both sides pinned
    ///   explicitly (never inherited from frame props, so the de-risked command is exactly
    ///   what runs);
    /// - specs equal but the input was assumed → `setparams` tags the frames with the
    ///   assumption *without touching pixels*. This is load-bearing, not cosmetic: the
    ///   encoder's `-colorspace`-family flags (`encoderArgs`) are conversion *requests* to
    ///   ffmpeg's filter-graph color negotiation — left untagged, the frames would be
    ///   auto-converted using ffmpeg's own input guess instead of ours (proven in the shell:
    ///   an untagged 601 source "tagged" bt709 via flags alone shifted to real 709 bytes);
    /// - specs equal and fully probed → nothing; the decoded frame props already match the
    ///   encoder flags, and the negotiation is a proven byte-stable identity.
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

    /// ffprobe color names map 1:1 onto the `colorspace` filter's option tokens for the whole
    /// SD/HD SDR domain (bt709/bt470bg/smpte170m — shell-verified); the few spellings that
    /// differ are aliased here. An unknown name passes through and fails the encode loudly
    /// rather than guessing.
    private static func filterColorToken(_ probed: String) -> String {
        switch probed {
        case "iec61966-2-1": return "srgb"
        case "iec61966-2-4": return "xvycc"
        case "bt2020nc": return "bt2020ncl"
        default: return probed
        }
    }

    /// The export-log line naming the color spec assumed for an untagged source converting
    /// toward a tagged target (issue #35) — nil when the source is fully tagged or the target
    /// imposes no complete spec. Plain language: the maintainer reads these, not ffprobe.
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

    // The encoder, profile token, and level tokens come from EncoderSelection — the one
    // table both re-encode paths share (ADR-0011 consequences). Conform additionally pins
    // level + color range; M2 carries them through by copy.
    private static func encoderArgs(target: VideoProperties, crf: Int? = nil,
                                    reorderDepth: Int = 1) -> [String] {
        var args = ["-c:v", EncoderSelection.encoder(for: target.codec),
                    "-profile:v", profile(target)]
        // The conform's rate control (issue #105 follow-up): an explicit CRF when the
        // settings carry one, else the encoder default — byte-identical to before the
        // knob existed. x264/x265 only (the `-crf` wrapper flag, de-risked in the shell
        // on both encoders × all three piece containers alongside the params flags
        // below); MPEG-2 has no CRF and takes its established default path.
        switch target.codec {
        case "hevc":
            if let crf { args += ["-crf", String(crf)] }
            args += ["-x265-params", x265Params(target, reorderDepth: reorderDepth)]
        case "mpeg2video":
            // MPEG-2 has no B-pyramid (its B-frames never reference other B-frames), so its
            // decode-order timestamps are already monotonic — no monotonic-DTS workaround needed.
            if isInterlaced(target.fieldOrder) {
                args += ["-flags", "+ildct+ilme"]
            }
        default:   // h264
            if let crf { args += ["-crf", String(crf)] }
            if let lvl = EncoderSelection.h264Level(target.level) { args += ["-level", lvl] }
            // Without these libx264 codes the combed frames as progressive pictures
            // (frame-level `interlaced_frame=0`) whatever the filter chain did; only the
            // Matroska tag would claim otherwise (issue #119, ADR-0011).
            if isInterlaced(target.fieldOrder) {
                args += ["-flags", "+ildct+ilme"]
            }
            // Match the join's reorder depth (ADR-0026): a shallow join drops libx264's
            // default B-pyramid — with it, B-frames reference other B-frames and the piece
            // needs a depth of 2, which Matroska can only carry when the join's first piece
            // declares it; misread, the final stream-copy mux collapses pairs of frames onto
            // a single PTS (the duplicate/gapped timestamps bug). One level of B-frames is
            // kept either way (compression), just not always the pyramid.
            args += EncoderSelection.encoderParams(
                EncoderSelection.reorderDepthParams(depth: reorderDepth, forCodec: target.codec),
                forCodec: target.codec)
        }
        // Drop an unmapped profile rather than guess (a wrong token aborts the encode).
        if args.count >= 4, args[2] == "-profile:v", args[3].isEmpty {
            args.removeSubrange(2...3)
        }
        if let range = target.colorRange { args += ["-color_range", range] }
        // A fully-tagged target gets its triple written into the VUI explicitly rather than
        // relying on frame-prop propagation alone (issue #35). Safe only because `colorStage`
        // guarantees the frames reaching the encoder already carry exactly these values —
        // on untagged frames these flags would trigger ffmpeg's own auto-conversion (see
        // `colorStage`); with matching frame props they are a byte-stable identity.
        if let spec = targetColorSpec(target) {
            args += ["-color_primaries", spec.primaries, "-color_trc", spec.transfer,
                     "-colorspace", spec.matrix]
        }
        return args
    }

    private static func profile(_ target: VideoProperties) -> String {
        EncoderSelection.encoderProfile(target.profile, codec: target.codec) ?? ""
    }

    /// libx265 params: quiet logging plus the target's level as `level-idc` (HEVC's probed
    /// `level` is `general_level_idc` = level × 30, e.g. 123 → 4.1).
    private static func x265Params(_ target: VideoProperties, reorderDepth: Int = 1) -> String {
        var p = "log-level=error"
        if let lvl = EncoderSelection.hevcLevel(target.level) {
            p += ":level-idc=\(lvl)"
        }
        // Match the join's reorder depth for the same reason as the libx264 path (see
        // encoderArgs), through the same shared entry so the two can't drift.
        for entry in EncoderSelection.reorderDepthParams(depth: reorderDepth, forCodec: target.codec) {
            p += ":\(entry)"
        }
        return p
    }

    // MARK: - Field order / aspect / rate helpers

    /// Internal (not private): the preview's spatial conform chain shares this scan
    /// check so the two can't drift (ADR-0012).
    static func isInterlaced(_ field: String?) -> Bool {
        MatchEvaluator.scanDirection(field) != "progressive"
    }

    private static func topFieldFirst(_ field: String?) -> Bool {
        MatchEvaluator.scanDirection(field) == "tff"
    }

    private static func displayAspectsMatch(source: VideoProperties, target: VideoProperties) -> Bool {
        abs(displayAspect(source) - displayAspect(target)) < 0.01
    }

    /// Internal (not private): the preview's spatial conform chain shares this DAR
    /// computation so the two can't drift (ADR-0012).
    static func displayAspect(_ v: VideoProperties) -> Double {
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
    /// Internal (not private): the repaired re-encode's fps fill (issue #47) shares it
    /// so the two paths can't drift on the token spelling.
    static func fpsToken(_ rate: String, double: Bool) -> String {
        let p = rate.split(separator: "/").compactMap { Int($0) }
        guard p.count == 2, p[1] != 0 else { return double ? "50" : "25" }
        let num = double ? p[0] * 2 : p[0]
        return p[1] == 1 ? "\(num)" : "\(num)/\(p[1])"
    }

    /// Frames-per-second as a Double from an ffprobe "num/den" rate ("25/1" → 25.0, "30000/1001"
    /// → 29.97). `nil` for an unparseable/degenerate rate. Internal (not private): the
    /// repaired re-encode's slot budget (issue #47) shares it.
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
