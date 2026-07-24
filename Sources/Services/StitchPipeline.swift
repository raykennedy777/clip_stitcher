import Foundation

/// The headless probe → index → plan → export orchestration behind the `clipstitch`
/// CLI (issue #105): what `ProjectDocument` does for the GUI, minus everything only a
/// GUI needs (bookmarks, undo, published state, import throttling for responsiveness).
/// Every engine decision is the shared one — `MediaProbe`, `FrameIndexer`,
/// `FieldCodingDetector`, `DamageDetector`, `AudioSourceResolver`, `ExportPlanner`,
/// `AudioCodecPolicy`, `ExportEngine` — so the CLI can never stitch differently than
/// the app (ADR-0025).
///
/// Error classes are load-bearing (the CLI maps them to exit codes): `StitchJobError`
/// means the job is wrong or doesn't fit its sources; `FFError` means a source
/// couldn't be probed/indexed (or the ff-tools are missing); `ExportError` (and
/// anything else) means planning/producing the output failed.
enum StitchPipeline {
    /// What a successful run wants to tell the caller: the same non-fatal notices the
    /// GUI shows after `.done` (repair reports, conform color assumptions, codec
    /// fallbacks).
    struct Outcome {
        var warnings: [String] = []
    }

    /// Everything one *source file* contributes, probed/indexed once however many
    /// clips reference it — the CLI equivalent of the document's per-clip caches, keyed
    /// by path because a Stitch Job's whole point is many clips cut from few files
    /// (the frame index scan is linear in file size; re-scanning a multi-GB capture
    /// per clip would dominate the run).
    struct SourceFacts {
        var url: URL
        var probe: MediaProbe.Result
        var index: FrameIndex
        var fieldCoded: Bool
        var damageZones: [DamageZone]
    }

    /// Runs a validated job end to end, writing the connected output to `output`.
    /// `log` receives human-readable stage lines (the CLI sends them to stderr);
    /// `progress` is the engine's 0…1 export fraction.
    @discardableResult
    static func run(job: StitchJob, output: URL,
                    log: @escaping (String) -> Void = { _ in },
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Outcome {
        let settings = try job.outputSettings()

        // 1. Probe + index each distinct source once, in first-appearance order.
        var facts: [String: SourceFacts] = [:]
        for jobClip in job.clips {
            let path = (jobClip.path as NSString).expandingTildeInPath
            guard facts[path] == nil else { continue }
            guard FileManager.default.fileExists(atPath: path) else {
                throw StitchJobError.missingSource(jobClip.path)
            }
            let url = URL(fileURLWithPath: path)
            log("Probing \(url.lastPathComponent)…")
            let probe = try await MediaProbe.probe(url: url)
            guard probe.video != nil else {
                // The GUI refuses audio-only sources at import (issue #83); the CLI
                // classifies the same fact as a probe-stage failure — the file was
                // readable but isn't usable video.
                throw FFError.probeFailed("“\(url.lastPathComponent)” has no video track.")
            }
            log("Indexing \(url.lastPathComponent)…")
            let scan = try await FrameIndexer.scanAllStreams(url: url)
            // Same import-time verdicts as the GUI: the field-coded check needs the
            // index's measured cadence (issue #46), and damage detection feeds the
            // planner's repaired segments (issues #45/#47) — both degrade safely on
            // clean sources.
            let fieldCoded = FieldCodingDetector.isFieldCoded(
                packetPts: scan.index.pts,
                frameRates: [probe.video?.frameRate, probe.videoCodecFrameRate])
            let damageZones = await DamageDetector.detectZones(
                url: url, scan: scan, containerStart: probe.containerStart)
            if !damageZones.isEmpty {
                log("Found \(damageZones.count) damage zone\(damageZones.count == 1 ? "" : "s") in \(url.lastPathComponent).")
            }
            facts[path] = SourceFacts(url: url, probe: probe, index: scan.index,
                                      fieldCoded: fieldCoded, damageZones: damageZones)
        }

        // 2. Materialize the model clips, refusing job/source mismatches the pure
        //    validation couldn't see (frame ranges vs the real count, audio stream
        //    indices vs the real stream list). Refusal, not the GUI's reconciliation:
        //    a script asked for exact coordinates, so silently exporting different
        //    ones would corrupt the caller's timeline math.
        var clips: [Clip] = []
        for (i, jobClip) in job.clips.enumerated() {
            let f = facts[(jobClip.path as NSString).expandingTildeInPath]!
            for frame in [jobClip.inFrame, jobClip.outFrame].compactMap({ $0 })
            where frame >= f.index.count {
                throw StitchJobError.frameOutOfRange(clip: i, frame: frame,
                                                     frameCount: f.index.count)
            }
            for t in jobClip.audioTracks ?? [] where t >= f.probe.audioTracks.count {
                throw StitchJobError.audioTrackOutOfRange(clip: i, index: t,
                                                          available: f.probe.audioTracks.count)
            }
            var clip = jobClip.modelClip(probe: f.probe, frameCount: f.index.count)
            clip.fieldCoded = f.fieldCoded
            clip.damageZones = f.damageZones
            clips.append(clip)
        }
        let target = clips[job.targetIndex!]   // validate() guaranteed exactly one

        // 3. Plan every clip — the same pure planner call the document makes, with the
        //    same warnings surfaced (they go to stderr instead of a Done panel).
        var outcome = Outcome()
        var items: [ExportItem] = []
        for (i, clip) in clips.enumerated() {
            let f = facts[(job.clips[i].path as NSString).expandingTildeInPath]!
            // No external audio files in the CLI contract, so the resolver can't
            // actually throw its missing-external error here.
            let audioSources = try AudioSourceResolver.resolveSources(
                for: clip, missingExternal: .throwError)
            let item = try ExportPlanner.planItem(
                for: ExportPlanner.ClipInput(clip: clip, url: f.url, index: f.index,
                                             containerStart: f.probe.containerStart,
                                             audioSources: audioSources,
                                             audioMixFilters: AudioSourceResolver.resolveMixFilters(for: clip)),
                target: target, settings: settings)
            if let conform = item.conform,
               let note = ConformEngine.assumedColorWarning(
                   clipName: clip.displayName,
                   source: conform.sourceVideo, target: conform.targetVideo) {
                outcome.warnings.append(note)
            }
            if settings.type != .audioOnly,
               let note = ExportPlanner.repairReport(
                   clipName: clip.displayName, zones: clip.damageZones,
                   windowStart: item.audioStart, windowEnd: item.audioEnd,
                   trimEnd: item.truncatedEndingTrim,
                   frameInterval: ExportPlanner.frameDuration(clip.video?.frameRate)) {
                outcome.warnings.append(note)
            }
            items.append(item)
        }
        if settings.container == .mp4 && items.contains(where: { $0.codec == "mpeg2video" }) {
            outcome.warnings.append("MPEG-2 video sits awkwardly in MP4 (possible glitch at joins) — choose the TS container for this footage.")
        }

        // 4. Output audio tracks + codec, exactly the document's derivation: the
        //    rebuilt audio conforms to the target clip's codec (ADR-0010), track
        //    count/formats follow the richest clip target-first (ADR-0014), and an
        //    audio-only output keeps one track (a single elementary stream).
        let targetAudioCodec = target.audio?.codec
        let audio = settings.type == .audioOnly
            ? AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: targetAudioCodec)
            : AudioCodecPolicy.resolveAudioCodec(targetCodec: targetAudioCodec, container: settings.container)
        if audio.fellBack, let wanted = targetAudioCodec {
            let dest = settings.type == .audioOnly
                ? "an audio file" : "the \(settings.container.fileExtension.uppercased()) container"
            outcome.warnings.append("\(wanted.uppercased()) audio can’t go in \(dest) — exporting AAC audio instead.")
        }
        var tracks = AudioSourceResolver.resolveOutputTracks(target: target, clips: clips)
        if settings.type == .audioOnly { tracks = Array(tracks.prefix(1)) }

        log("Exporting \(items.count) clip\(items.count == 1 ? "" : "s") to \(output.lastPathComponent)…")
        try await ExportEngine.export(items: items, settings: settings,
                                      audioCodec: audio.encoder, tracks: tracks,
                                      to: output, progress: progress)
        return outcome
    }

    /// The output-file extension this job must be written under, or nil when the job
    /// imposes none. A video output must carry the container's extension — ffmpeg
    /// picks the final muxer from the destination's extension, so an `out.mp4`
    /// against an MKV job would silently produce a container the pieces weren't
    /// planned for; the CLI refuses the mismatch up front. An audio-only output's
    /// extension follows the codec the export resolves *after* probing the target
    /// (`AudioCodecPolicy.audioFileExtension`), which the pre-probe check can't know
    /// — no requirement, the muxer ffmpeg picks from the given name is the one that
    /// matters.
    static func requiredExtension(job: StitchJob) throws -> String? {
        let settings = try job.outputSettings()
        return settings.type == .audioOnly ? nil : settings.container.fileExtension
    }
}
