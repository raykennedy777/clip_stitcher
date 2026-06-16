import Foundation

/// The **Clip Doctor** repair-only export (ADR-0021, issue #52): take one damaged source
/// and write a full-length repaired copy in the source's **own** codec and container —
/// bit-identical stream copy everywhere, re-encoded repaired segments only across the
/// recorded damage zones — then **auto-verify** by re-running damage detection on the
/// output and producing a verdict.
///
/// It is the whole-file case of the smart-render export: `ExportPlanner.videoTreatment`
/// with no in/out trim and **no target** never conforms, so the planner already returns a
/// whole-file `.smartRender` plan (bit-exact copy spans, repaired re-encode segments). The
/// three differences from the join/conform export (`ExportEngine`) are:
///   1. copy spans use the **bounded input-seek keyframe copy**
///      (`BoundaryReencodeEngine.CopyStrategy.boundedKeyframe`): a whole-file plan's many
///      copy spans make the segment-muxer's per-span full-file reads unusable (#52);
///   2. audio is rebuilt in each track's **own source codec** at source bitrate with gap
///      silence-fill — no target conform and no `first_pts=0`, so the source's priming
///      offset against the preserved video start_time is kept (issue #44 recipe);
///   3. the output is a sibling `_repaired` file in the source container, staged on the
///      **same volume** and **atomically moved** into place only on success — the source
///      is never touched, and an existing destination is not clobbered without intent.
///
/// Two video paths share this orchestration. A **progressive** source is smart-rendered
/// (issue #52): copy the untouched footage byte-for-byte, re-encode only the damaged
/// stretches. A **field-coded (PAFF)** source can't be smart-render spliced — a no-IDR
/// PAFF stream has no resume seam (ADR-0022) — so it takes the **damage-to-EOF** repair:
/// copy the clean head byte-for-byte up to the keyframe before the first damage, then
/// re-encode everything from there to EOF as MBAFF H.264 (issue #54). Everything after the
/// video piece — the in-codec gap-filled audio, the staged atomic move, and the auto-verify
/// — is identical for both.
enum ClipDoctorEngine {
    /// One source audio track to rebuild (issue #52), resolved from the source's probe.
    struct AudioTrack: Equatable {
        /// The source's Nth audio stream, 0-based among audio streams (`0:a:N`).
        var streamIndex: Int
        var sampleRate: Int
        /// The ffmpeg encoder for the source codec — `aac`, `mp2`, `ac3`, `libmp3lame`,
        /// or `aac_at` (AudioToolbox) when the source is HE-AAC.
        var encoder: String
        /// Target bitrate in bits/sec — the source's own when the container reported it.
        var bitrate: Int
        /// Encode with AudioToolbox's numeric HE-AAC profile (`-profile:a 4`) — the native
        /// `aac` encoder is AAC-LC only, and `-profile:a aac_he` is not a valid token in
        /// this ffmpeg build (de-risked 2026-06-14); the numeric profile is.
        var heAAC: Bool
    }

    /// The auto-verify outcome (issue #52). The repaired file is **never discarded** — a
    /// surviving zone is a soft warning, an unreadable re-scan is inconclusive; either way
    /// the file is kept for review.
    struct Verdict: Equatable {
        enum Outcome { case clean, zonesRemain, inconclusive }
        var outcome: Outcome
        /// Zones detection still found on the output (empty when clean/inconclusive).
        var survivingZones: [DamageZone]
        /// A human-readable line for the export-completion report.
        var message: String
        var clean: Bool { outcome == .clean }
    }

    struct Result {
        var output: URL
        var verdict: Verdict
        /// Damage zones the repair addressed (video re-encoded, audio silence-filled).
        var repairedZoneCount: Int
    }

    enum DoctorError: LocalizedError {
        case destinationExists(URL)
        case destinationIsSource
        /// A field-coded source whose scan order is neither labelled nor measurable (issue
        /// #60): repairing it would risk re-encoding the damage-to-EOF tail with the wrong
        /// field polarity (combing on motion), which the auto-verify can't catch — so refuse.
        case fieldOrderUndetermined
        /// A field-coded source whose codec isn't H.264 (issue #57): the damage-to-EOF tail is
        /// always MBAFF H.264, so a non-H.264 head would concat into a mixed-codec track. Refuse
        /// rather than ship something most players can't decode past the seam.
        case unsupportedFieldCodedCodec(String?)

        var errorDescription: String? {
            switch self {
            case .destinationExists(let url):
                return "A repaired file already exists at \(url.lastPathComponent); it was not replaced."
            case .destinationIsSource:
                return "The repaired file would overwrite the source; refusing."
            case .fieldOrderUndetermined:
                return "This clip’s field order couldn’t be determined, so it can’t be safely repaired — "
                    + "repairing it could reverse the fields. It needs a known top- or bottom-field-first scan order."
            case .unsupportedFieldCodedCodec(let codec):
                let named = codec.map { "\(displayCodecName($0)) " } ?? ""
                return "Field-coded \(named)clips can’t be repaired yet — Clip Doctor’s field-coded repair "
                    + "currently supports H.264 sources only."
            }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// The sibling repaired-output URL: `<stem>_repaired.<ext>` next to the source, in the
    /// same container. e.g. `.../clip.ts` → `.../clip_repaired.ts`.
    static func repairedSibling(of source: URL) -> URL {
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        return source.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_repaired").appendingPathExtension(ext)
    }

    /// Rewrites the whole-file smart-render plan into the field-coded **damage-to-EOF**
    /// shape (issue #54, ADR-0022). A no-IDR PAFF source cannot be smart-render spliced:
    /// the MBAFF→PAFF resume seam is a hard container-layer wall (proven), so the only
    /// repair that decodes clean from start to EOF keeps exactly **one** copy→re-encode
    /// transition — the entry. The head is stream-copied byte-for-byte up to the seam, then
    /// everything from the seam to the file end is one MBAFF re-encode carrying every
    /// video-affecting zone (each dropped + frame-filled by the tail encode).
    ///
    /// The seam must sit on a real **keyframe**: the head copy ends there (a TS stream copy
    /// can only split at a keyframe) and the MBAFF tail re-encodes from it as a forced IDR
    /// (the clean entry). The planner's first-repair start is a *leading-picture-adjusted*
    /// copy end (`keyframe − n_leading`) — correct for a segment-muxer DTS cut, but not a
    /// keyframe, so `-segment_frames` there would split at the *next* keyframe and overlap
    /// the tail (the seam then decodes with a DTS discontinuity the re-scan reads as fresh
    /// damage). Snapping to the keyframe at or before it lands the seam exactly where the
    /// head ends and the tail's IDR begins — adjacent, no overlap, no gap. A clip damaged
    /// before its first keyframe has no head copy and converges on a full re-encode —
    /// correct, just no longer minimal. Pure, so the transform is unit-tested without ffmpeg.
    static func damageToEOFPlan(_ segments: [PlannedSegment], index: FrameIndex,
                                zones: [DamageZone]) -> [PlannedSegment] {
        guard let firstRepair = segments.firstIndex(where: { $0.kind == .reEncode }) else {
            return segments   // no damage in range — defensive; the caller only routes damaged clips.
        }
        let seam = index.keyframeIndex(atOrBefore: segments[firstRepair].range.lowerBound)
        var plan: [PlannedSegment] = []
        if seam > 0 {
            plan.append(PlannedSegment(kind: .copy, range: 0..<seam, outCutKeyframe: nil))
        }
        plan.append(PlannedSegment(kind: .reEncode, range: seam..<index.count,
                                   outCutKeyframe: nil, damage: zones.filter(\.affectsVideo)))
        return plan
    }

    /// The field-coded (PAFF) repair specialization (issue #54, ADR-0022): the planner's
    /// generic whole-file smart-render plan collapsed to the damage-to-EOF shape, **paired
    /// with** the MBAFF tail encoder that re-encodes from the seam. They are returned together
    /// so a caller can't pair a damage-to-EOF plan with the source-matched progressive encoder
    /// (or vice versa) and ship a broken tail. Damage-to-EOF is a Clip-Doctor-only concept — it
    /// never reaches the join/conform export's `ExportPlanner.VideoTreatment` verdict, which
    /// only ever sees smart-render or conform — so the specialization lives here rather than as
    /// a planner treatment case (the layering decision recorded in ADR-0022). Pure; unit-tested.
    static func fieldCodedRepair(
        from segments: [PlannedSegment], index: FrameIndex, zones: [DamageZone],
        fieldOrder: String?
    ) -> (plan: [PlannedSegment], encoder: [String]) {
        (damageToEOFPlan(segments, index: index, zones: zones),
         BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: fieldOrder))
    }

    /// Whether Clip Doctor can repair a **field-coded** source of this codec (issue #57).
    /// The damage-to-EOF route copies the source-codec head byte-for-byte but re-encodes the
    /// tail as **MBAFF H.264** (`mbaffRepairVideoArgs` hardcodes libx264, and ADR-0022's recipe
    /// was only de-risked on H.264 PAFF). A non-H.264 field-coded source would therefore concat
    /// a `<source-codec>` head with an H.264 tail into one track — a mid-file codec switch most
    /// players can't decode past the seam. So field-coded repair is H.264-only; the cadence
    /// detector that flags a source field-coded is codec-agnostic, so this guard is what stops
    /// an MPEG-2/HEVC field-coded clip from shipping a broken mixed-codec output. (Progressive
    /// repair is a same-codec smart render and has no such limit.)
    static func canRepairFieldCoded(codec: String?) -> Bool {
        codec == "h264"
    }

    // MARK: - Field order detection (#60)

    /// Whether a probed `field_order` is a definite scan order the repair can trust without
    /// measuring (issue #60): ffprobe's four interlaced labels. `nil`, `"unknown"`,
    /// `"progressive"` (a field-coded source mislabelled), or any unrecognised token is **not**
    /// definite — the MBAFF tail's `-top` must be *measured* with `idet` rather than defaulting
    /// to top-first, which would field-reverse a bottom-first source's whole damage-to-EOF tail.
    static func isDefiniteFieldOrder(_ fieldOrder: String?) -> Bool {
        switch fieldOrder {
        case "tt", "tb", "bb", "bt": return true
        default: return false
        }
    }

    /// ffmpeg `idet` field-order detection pass (issue #60): decode a short run of frames
    /// through the interlace detector so it tallies TFF vs BFF. `-v info` so the filter prints
    /// its cumulative summary (it logs at info level — `-v error` suppresses it, de-risked); a
    /// damaged source's per-frame decoder warnings are auto-deduplicated by ffmpeg and bounded
    /// by the frame budget, and `ProcessRunner`'s tail keeps the trailing summary regardless.
    /// Run only when the source's own `field_order` is indeterminate (`isDefiniteFieldOrder`
    /// false) — a labelled source keeps the metadata fast path. De-risked on the real PAFF
    /// capture: `idet` reports TFF unanimously (501/501, 801/801), matching the metadata `tt`.
    static func fieldOrderDetectionArguments(source: URL, frames: Int = 500) -> [String] {
        ["-v", "info", "-i", source.path, "-vf", "idet",
         "-frames:v", String(frames), "-an", "-f", "null", "-"]
    }

    /// One `idet` "Multi frame detection" tally.
    struct IdetTally: Equatable { var tff, bff, progressive, undetermined: Int }

    /// The cumulative tally from an `idet` pass's stderr (issue #60): the **last** "Multi frame
    /// detection" line — idet's multi-frame analysis is steadier than its single-frame one, and
    /// the final such line is the cumulative total (earlier ones are running subtotals). `nil`
    /// when no summary is present (too few frames decoded, or a failed pass).
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

    /// The scan order an `idet` tally implies, or `nil` when the measurement is inconclusive
    /// (issue #60). Decisive only when the interlaced frames clearly dominate the sample **and**
    /// one polarity clearly dominates the interlaced frames (≥ 90 %) — otherwise refuse rather
    /// than guess a `-top` that could field-reverse the whole tail. Returns `"tt"` (TFF) or
    /// `"bb"` (BFF), the two orders the MBAFF `-top` flag distinguishes.
    static func fieldOrderFromIdet(_ tally: IdetTally) -> String? {
        let interlaced = tally.tff + tally.bff
        let total = interlaced + tally.progressive + tally.undetermined
        guard total >= 100, interlaced * 2 >= total else { return nil }   // a real, mostly-interlaced sample
        let winner = max(tally.tff, tally.bff)
        guard winner * 10 >= interlaced * 9 else { return nil }            // one polarity ≥ 90 %
        return tally.tff >= tally.bff ? "tt" : "bb"
    }

    /// Resolves one probed audio stream to a repair track (issue #52): the source codec's
    /// ffmpeg encoder (HE-AAC → AudioToolbox `aac_at` so the profile survives — the native
    /// `aac` encoder is LC-only), the source bitrate when known (a per-channel default
    /// otherwise), and the stream's own rate. `audioStreamIndex` is its `0:a:N` position.
    static func audioTrack(from detail: MediaProbe.AudioStreamDetail,
                           audioStreamIndex: Int) -> AudioTrack {
        let isHE = detail.codecName == "aac"
            && (detail.profile?.range(of: "HE", options: .caseInsensitive) != nil)
        let encoder = detail.codecName == "aac"
            ? (isHE ? "aac_at" : "aac")
            : (AudioCodecPolicy.audioEncoder(for: detail.codecName) ?? AudioCodecPolicy.fallbackAudioCodec)
        let bitrate = detail.bitrate ?? (detail.channels <= 1 ? 96_000 : 128_000)
        return AudioTrack(streamIndex: audioStreamIndex, sampleRate: detail.sampleRate,
                          encoder: encoder, bitrate: bitrate, heAAC: isHE)
    }

    /// Final-mux args for a repair (issue #52): copy the repaired video piece's video and
    /// rebuild every source audio track **in its own codec** with gap silence-fill,
    /// preserving track order. Each leg is `aresample=<rate>:async=1` — the issue-#44
    /// gap-fill **without** `first_pts=0`, so the audio keeps its source priming offset
    /// against the preserved video start_time (≈21 ms lead on 1844) instead of being
    /// pulled to zero and desyncing. `-max_error_rate 1.0` on the source input lets a
    /// track survive a dead zone (the 1842 MP2 zone aborts at the default ⅔ otherwise).
    /// HE-AAC is preserved via AudioToolbox's numeric profile (`-c:a aac_at -profile:a 4`).
    /// `-y`: the staged temp path is ours, so a stale one is overwritten silently.
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

    /// The auto-verify verdict from the re-scan (issue #52). Clean = zero zones; surviving
    /// zones are named (clip time, capped at six like the source row's damage line); an
    /// unscanned output is inconclusive. The file is kept in every case.
    static func makeVerdict(clipName: String, scanned: Bool, survivingZones: [DamageZone]) -> Verdict {
        guard scanned else {
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

    /// The sheet's non-AV-stream notice (ADR-0021, issue #53): the engine carries video
    /// and audio only, so subtitle/teletext/data/attachment streams are dropped — say so
    /// rather than dropping them silently. `nil` when the source has none. Counts per kind
    /// in container order so the wording is deterministic.
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

    /// The up-front notice + opt-in text for a **field-coded (PAFF)** repair (issue #54,
    /// ADR-0022). Unlike the progressive smart-render repair — which stream-copies the
    /// untouched footage byte-for-byte — a field-coded source can't be spliced, so the clip
    /// is re-encoded in full from the first damage to the end: high-quality but not
    /// bit-for-bit identical, and slow on a long capture. The sheet shows this before Repair
    /// runs and requires an explicit opt-in. Time estimate scales off the clip duration (the
    /// measured throughput is ~4.5× realtime typical, down to ~1× on a slow/busy Mac).
    /// Banned-word clean (no fix/heal/patch/error concealment). Pure for unit tests.
    static func fieldCodedReencodeNotice(clipName: String, duration: Double?) -> String {
        let base = "“\(clipName)” stores two half-pictures per frame, so it can’t be repaired in place — "
            + "the whole clip is re-encoded from the first damage to the end. The result is "
            + "high-quality but not bit-for-bit identical to the source."
        guard let duration, duration > 0 else { return base }
        return base + " Expect roughly \(roughDurationPhrase(duration / 4.5)) on this Mac, "
            + "and up to about \(roughDurationPhrase(duration)) on a slow or busy one."
    }

    /// A rounded, no-false-precision duration phrase for the re-encode estimate (HIG):
    /// "a minute or two", whole minutes, then half-hour steps. The half-hour ladder is
    /// `ExportProgress.halfHourPhrase` — the same rounding the live ETA label uses, so the
    /// up-front field-coded estimate and the progress readout can't drift apart.
    private static func roughDurationPhrase(_ seconds: Double) -> String {
        if seconds < 90 { return "a minute or two" }
        if seconds < 3300 {
            let m = max(2, Int((seconds / 60).rounded()))
            return "\(m) minutes"
        }
        return ExportProgress.halfHourPhrase(seconds)
    }

    /// The import banner's suggestion line (issue #55): names the freshly-detected
    /// damage and offers Clip Doctor. Pure so the wording stays banned-word-clean and
    /// testable; positions live on the row's damage line, not here.
    static func suggestionBannerText(clipName: String, zoneCount: Int) -> String {
        let zones = zoneCount == 1 ? "a damage zone" : "\(zoneCount) damage zones"
        return "“\(clipName)” has \(zones). Clip Doctor can repair it."
    }

    /// An ffprobe `codec_name` as a reader-facing word for a notice (issue #57). The handful
    /// of names Clip Doctor surfaces; an unknown name is upper-cased rather than guessed.
    private static func displayCodecName(_ codec: String) -> String {
        switch codec {
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "mpeg2video": return "MPEG-2"
        default: return codec.uppercased()
        }
    }

    /// ffprobe's `codec_type` as a reader-facing word. Unknown kinds pass through.
    private static func displayKind(_ codecType: String) -> String {
        switch codecType {
        case "subtitle": return "subtitle"
        case "data": return "data"
        case "attachment": return "attachment"
        default: return codecType
        }
    }

    /// Joins phrases into a list: "a", "a and b", "a, b and c".
    private static func listPhrase(_ phrases: [String]) -> String {
        switch phrases.count {
        case 0: return ""
        case 1: return phrases[0]
        case 2: return "\(phrases[0]) and \(phrases[1])"
        default: return phrases.dropLast().joined(separator: ", ") + " and \(phrases.last!)"
        }
    }

    // MARK: - Orchestration

    /// Repairs one damaged source into a sibling `_repaired` file in the source container,
    /// then auto-verifies it (issue #52). `clip` supplies the probed video properties and
    /// the recorded damage zones (its in/out points are ignored — Clip Doctor always
    /// repairs the whole file); `index`/`containerStart` are the import-time cache. Audio
    /// tracks are resolved from a fresh probe of the source.
    ///
    /// `destination` defaults to the `_repaired` sibling. Without `overwrite`, an existing
    /// destination is refused rather than clobbered; the source is never written to.
    /// `progress` reports 0…1 (video production 0…0.85, audio mux 0.85…0.97, verify → 1.0).
    static func repair(
        source: URL, clip: Clip, index: FrameIndex, containerStart: Double,
        destination: URL? = nil, overwrite: Bool = false,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Result {
        guard let video = clip.video else { throw ExportError.invalidPlan }
        let fieldCoded = clip.fieldCoded == true
        // The field-coded route re-encodes its tail as MBAFF H.264 while byte-copying the
        // source-codec head, so a non-H.264 field-coded source would ship a mixed-codec concat
        // (issue #57). The cadence-based detector is codec-agnostic, so refuse here rather than
        // produce something most players can't decode past the seam. Progressive repair is
        // same-codec and unaffected.
        if fieldCoded, !canRepairFieldCoded(codec: video.codec) {
            throw DoctorError.unsupportedFieldCodedCodec(video.codec)
        }

        let dest = destination ?? repairedSibling(of: source)
        guard dest.standardizedFileURL != source.standardizedFileURL else {
            throw DoctorError.destinationIsSource
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) && !overwrite {
            throw DoctorError.destinationExists(dest)
        }

        let ffmpeg = try FFTools.ffmpegURL()
        let ext = source.pathExtension.lowercased()

        // The whole-file repair plan: no trim, no target ⇒ never conform (ADR-0011) ⇒ a
        // pure whole-file smart-render plan (copy spans + repaired re-encode segments).
        var wholeFile = clip
        wholeFile.inPoint = nil
        wholeFile.outPoint = nil
        let treatment = try ExportPlanner.videoTreatment(
            for: wholeFile, target: nil, index: index, containerStart: containerStart)
        guard case .smartRender(let segments, let progressiveEncoder) = treatment else {
            throw ExportError.invalidPlan   // target nil never yields .conform; defensive.
        }
        // A field-coded (PAFF) source can't be smart-render spliced (ADR-0022): collapse
        // the interleaved copy/repair plan to one copy head + one MBAFF re-encode to EOF,
        // and swap the source-matched progressive encoder for the MBAFF repair encoder.
        let plan: [PlannedSegment]
        let encoder: [String]
        if fieldCoded {
            // The MBAFF tail's `-top` follows the source scan order. Trust a definite probed
            // `field_order`; otherwise measure it with `idet` rather than assume top-first
            // (issue #60) — and refuse if even that is inconclusive, since a wrong polarity
            // field-reverses the whole tail and the auto-verify can't catch it.
            let order = try await resolveFieldOrder(ffmpeg, source: source, declared: video.fieldOrder)
            (plan, encoder) = fieldCodedRepair(
                from: segments, index: index, zones: clip.damageZones ?? [], fieldOrder: order)
        } else {
            plan = segments
            encoder = progressiveEncoder
        }

        // Resolve the source's audio tracks for an in-codec rebuild (order preserved).
        let details = await MediaProbe.audioStreamDetails(url: source)
        let tracks = details.enumerated().map { audioTrack(from: $1, audioStreamIndex: $0) }

        // Intermediates live in a throwaway temp dir; the final mux is staged on the
        // destination's own volume so the success move is an atomic same-volume rename.
        let work = fm.temporaryDirectory
            .appendingPathComponent("clipstitcher-doctor-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let staged = dest.deletingLastPathComponent()
            .appendingPathComponent("clipstitcher-doctor-staging-\(UUID().uuidString).\(ext)")
        defer {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: staged)   // present only on a failed/cancelled run
        }

        // 1. Produce the repaired video piece: bounded keyframe copy spans + repaired
        //    re-encode segments, concatenated and self-verified (frame count / decode /
        //    timestamps) by `produceVideoPiece` before it ships (ADR-0008).
        let videoPiece = try await BoundaryReencodeEngine.produceVideoPiece(
            ffmpeg, source: source, plan: plan, index: index, encoder: encoder,
            work: work, ext: ext, clipIndex: 0, codec: video.codec,
            containerStart: containerStart, frameRate: video.frameRate,
            sourceDamaged: true, copyStrategy: .boundedKeyframe, fieldCoded: fieldCoded,
            onProgress: { w in progress(0.85 * w) })

        // 2. Mux the repaired video with the in-codec, gap-filled audio into the staged file.
        let totalSpan = clip.duration
        try await runFFmpeg(ffmpeg, repairedMuxArguments(
            videoPiece: videoPiece, source: source, tracks: tracks, output: staged)) { t in
            progress(0.85 + 0.12 * ExportProgress.runFraction(outTime: t, expectedSeconds: totalSpan))
        }

        // 3. Atomic move into place — only now does the destination exist. A cancel or
        //    failure before this point leaves no `_repaired` file and never touches the
        //    source (the staged temp is cleaned by the defer).
        if overwrite { try? fm.removeItem(at: dest) }
        try fm.moveItem(at: staged, to: dest)
        progress(0.97)

        // 4. Auto-verify: re-run detection on the output. A failed re-scan is inconclusive,
        //    never a discard — the produced piece already passed its own verify gate.
        let scan = try? await FrameIndexer.scanAllStreams(url: dest)
        let verdict: Verdict
        if let scan {
            let outStart = await MediaProbe.containerStartTime(url: dest)
            let surviving = await DamageDetector.detectZones(
                url: dest, scan: scan, containerStart: outStart)
            verdict = makeVerdict(clipName: clip.displayName, scanned: true, survivingZones: surviving)
        } else {
            verdict = makeVerdict(clipName: clip.displayName, scanned: false, survivingZones: [])
        }
        progress(1.0)
        return Result(output: dest, verdict: verdict,
                      repairedZoneCount: (clip.damageZones ?? []).count)
    }

    /// Resolves the source's scan order for the MBAFF tail's `-top` flag (issue #60). A
    /// definite probed `field_order` (`tt`/`tb`/`bb`/`bt`) is trusted as-is — the fast path, no
    /// extra decode, the case the real labelled captures take. Otherwise the order is *measured*
    /// with a short `idet` pass rather than silently defaulting to top-first, which would
    /// field-reverse a bottom-first source's whole damage-to-EOF tail (combing on motion) while
    /// the auto-verify — which doesn't inspect field order — still reported clean. If even
    /// `idet` is inconclusive the repair refuses (`DoctorError.fieldOrderUndetermined`),
    /// consistent with the conservative H.264-only guard (issue #57), rather than guess.
    private static func resolveFieldOrder(_ ffmpeg: URL, source: URL, declared: String?) async throws -> String {
        if let declared, isDefiniteFieldOrder(declared) { return declared }
        let result = try await ProcessRunner.run(ffmpeg, fieldOrderDetectionArguments(source: source))
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        guard let tally = parseIdetTally(stderr), let order = fieldOrderFromIdet(tally) else {
            throw DoctorError.fieldOrderUndetermined
        }
        return order
    }

    /// Runs ffmpeg, turning a non-zero exit into `ExportError.cutFailed` with its stderr;
    /// streams `-progress` out_time to `onOutTime` (issue #9).
    ///
    /// The audio mux reads the whole source with `-max_error_rate 1.0`, and on a damaged
    /// multi-hour capture the decoders flood stderr (mmco/ref-frame/corrupt-packet lines)
    /// even at `-v error` — historically enough to overrun the ~64 KB OS pipe buffer and
    /// deadlock the run at 0% CPU, which froze the real 4.8 h repair (issue #54). `ProcessRunner`
    /// now drains stderr live into a bounded tail (issue #59), so the in-memory pipe is safe
    /// again; the failure detail is the tail's final fatal lines.
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
