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
/// Scope: the **progressive** path (issue #52). Field-coded (PAFF) sources take the full
/// interlaced re-encode (issue #54) and are refused here.
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
        case fieldCoded
        case destinationExists(URL)
        case destinationIsSource

        var errorDescription: String? {
            switch self {
            case .fieldCoded:
                return "Clip Doctor doesn’t support field-coded (interlaced PAFF) sources yet."
            case .destinationExists(let url):
                return "A repaired file already exists at \(url.lastPathComponent); it was not replaced."
            case .destinationIsSource:
                return "The repaired file would overwrite the source; refusing."
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
        guard clip.fieldCoded != true else { throw DoctorError.fieldCoded }
        guard let video = clip.video else { throw ExportError.invalidPlan }

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
        guard case .smartRender(let segments, let encoder) = treatment else {
            throw ExportError.invalidPlan   // target nil never yields .conform; defensive.
        }

        // Resolve the source's audio tracks for an in-codec rebuild (order preserved).
        let details = await MediaProbe.audioStreamDetails(url: source)
        let tracks = details.enumerated().map { audioTrack(from: $1, audioStreamIndex: $0) }

        // Intermediates live in a throwaway temp dir; the final mux is staged on the
        // destination's own volume so the success move is an atomic same-volume rename.
        let work = fm.temporaryDirectory
            .appendingPathComponent("vidconform-doctor-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let staged = dest.deletingLastPathComponent()
            .appendingPathComponent("vidconform-doctor-staging-\(UUID().uuidString).\(ext)")
        defer {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: staged)   // present only on a failed/cancelled run
        }

        // 1. Produce the repaired video piece: bounded keyframe copy spans + repaired
        //    re-encode segments, concatenated and self-verified (frame count / decode /
        //    timestamps) by `produceVideoPiece` before it ships (ADR-0008).
        let videoPiece = try await BoundaryReencodeEngine.produceVideoPiece(
            ffmpeg, source: source, plan: segments, index: index, encoder: encoder,
            work: work, ext: ext, clipIndex: 0, codec: video.codec,
            containerStart: containerStart, frameRate: video.frameRate,
            sourceDamaged: true, copyStrategy: .boundedKeyframe,
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

    /// Runs ffmpeg, turning a non-zero exit into `ExportError.cutFailed` with its stderr;
    /// streams `-progress` out_time to `onOutTime` (issue #9).
    private static func runFFmpeg(_ ffmpeg: URL, _ args: [String],
                                  onOutTime: @escaping @Sendable (Double) -> Void) async throws {
        let parser = ProgressParser()
        let result = try await ProcessRunner.run(ffmpeg, ExportProgress.progressArguments(args)) { chunk in
            if let t = parser.feed(chunk) { onOutTime(t) }
        }
        guard result.status == 0 else {
            throw ExportError.cutFailed(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
    }
}
