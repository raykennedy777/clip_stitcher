import Foundation

enum StitchPipeline {
    struct Outcome {
        var warnings: [String] = []
    }

    struct SourceFacts {
        var url: URL
        var probe: MediaProbe.Result
        var index: FrameIndex
        var fieldCoded: Bool
        var damageZones: [DamageZone]
    }

    struct Prepared {
        var job: StitchJob
        var settings: OutputSettings
        var facts: [String: SourceFacts]
        var clips: [Clip]
        var targetIndex: Int
        var items: [ExportItem]
        var audio: AudioCodecPolicy.AudioEncodeChoice
        var tracks: [AudioCodecPolicy.OutputAudioTrack]
        var warnings: [String]

        var target: Clip { clips[targetIndex] }

        func facts(forClip i: Int) -> SourceFacts {
            facts[(job.clips[i].path as NSString).expandingTildeInPath]!
        }
    }

    @discardableResult
    static func run(job: StitchJob, output: URL,
                    log: @escaping (String) -> Void = { _ in },
                    progress: @escaping @Sendable (Double) -> Void = { _ in },
                    indexCache: IndexCache? = nil,
                    pieceCache: PieceCache? = nil) async throws -> Outcome {
        let clock = StageClock()
        let prepared = try await prepare(job: job, log: log, indexCache: indexCache)
        log("Exporting \(prepared.items.count) clip\(prepared.items.count == 1 ? "" : "s") to \(output.lastPathComponent)…")
        try await ExportEngine.export(items: prepared.items, settings: prepared.settings,
                                      audioCodec: prepared.audio.encoder, tracks: prepared.tracks,
                                      to: output, progress: progress, log: log,
                                      pieceCache: pieceCache)
        if let pieceCache {
            log("Piece cache: \(pieceCache.hits) hits, \(pieceCache.misses) misses")
        }
        log("Total: \(StageClock.clockLabel(clock.seconds))")
        return Outcome(warnings: prepared.warnings)
    }

    static func prepare(job: StitchJob,
                        log: @escaping (String) -> Void = { _ in },
                        indexCache: IndexCache? = nil) async throws -> Prepared {
        let settings = try job.outputSettings()

        var facts: [String: SourceFacts] = [:]
        for jobClip in job.clips {
            let path = (jobClip.path as NSString).expandingTildeInPath
            guard facts[path] == nil else { continue }
            guard FileManager.default.fileExists(atPath: path) else {
                throw StitchJobError.missingSource(jobClip.path)
            }
            facts[path] = try await sourceFacts(url: URL(fileURLWithPath: path),
                                                cache: indexCache, log: log)
        }

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
        let target = clips[job.targetIndex!]

        let planClock = StageClock()
        var outcome = Outcome()
        var items: [ExportItem] = []
        for (i, clip) in clips.enumerated() {
            let f = facts[(job.clips[i].path as NSString).expandingTildeInPath]!
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
        log("Planned \(StageClock.count(items.count, "clip")): \(planClock.label)")
        if let note = ExportPlanner.reorderDepthWarning(items: items, settings: settings) {
            outcome.warnings.append(note)
        }
        if settings.container == .mp4 && items.contains(where: { $0.codec == "mpeg2video" }) {
            outcome.warnings.append("MPEG-2 video sits awkwardly in MP4 (possible glitch at joins) — choose the TS container for this footage.")
        }

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

        return Prepared(job: job, settings: settings, facts: facts, clips: clips,
                        targetIndex: job.targetIndex!,
                        items: items,
                        audio: audio, tracks: tracks, warnings: outcome.warnings)
    }

    static func sourceFacts(url: URL, cache: IndexCache?,
                            log: @escaping (String) -> Void) async throws -> SourceFacts {
        let identity = cache == nil ? nil : try? SourceIdentity.of(url)
        if let cache, let identity {
            let lookup = StageClock()
            if let hit = await cache.load(identity) {
                log("Index cache hit \(url.lastPathComponent): \(lookup.label), "
                    + "\(StageClock.count(hit.pts.count, "video frame")), \(StageClock.count(hit.damageZones.count, "zone"))")
                logDamageZones(hit.damageZones, url: url, log: log)
                return SourceFacts(url: url, probe: hit.probe, index: hit.index,
                                   fieldCoded: hit.fieldCoded, damageZones: hit.damageZones)
            }
            log("Index cache miss \(url.lastPathComponent)")
        }
        log("Probing \(url.lastPathComponent)…")
        let probeClock = StageClock()
        let probe = try await MediaProbe.probe(url: url)
        log("Probed \(url.lastPathComponent): \(probeClock.label)")
        guard probe.video != nil else {
            throw FFError.probeFailed("“\(url.lastPathComponent)” has no video track.")
        }
        log("Indexing \(url.lastPathComponent)…")
        let indexClock = StageClock()
        let scan = try await FrameIndexer.scanAllStreams(url: url)
        let packets = scan.streams.reduce(0) { $0 + $1.packets.count }
        log("Indexed \(url.lastPathComponent): \(indexClock.label), "
            + "\(StageClock.count(packets, "packet")), \(StageClock.count(scan.index.count, "video frame"))")
        let fieldCoded = FieldCodingDetector.isFieldCoded(
            packetPts: scan.index.pts,
            frameRates: [probe.video?.frameRate, probe.videoCodecFrameRate])
        let damageClock = StageClock()
        var candidates = 0
        let damageZones = await DamageDetector.detectZones(
            url: url, scan: scan, containerStart: probe.containerStart,
            onCandidates: { candidates = $0 })
        log("Damage scan \(url.lastPathComponent): \(damageClock.label), "
            + "\(StageClock.count(candidates, "candidate")), \(StageClock.count(damageZones.count, "zone"))")
        logDamageZones(damageZones, url: url, log: log)
        if let cache, let identity, (try? SourceIdentity.of(url)) == identity {
            await cache.store(IndexCache.Facts(probe: probe, pts: scan.index.pts, dts: scan.index.dts,
                                               keyframeFlags: scan.index.keyframeFlags,
                                               fieldCoded: fieldCoded, damageZones: damageZones),
                              for: identity)
        }
        return SourceFacts(url: url, probe: probe, index: scan.index,
                           fieldCoded: fieldCoded, damageZones: damageZones)
    }

    private static func logDamageZones(_ zones: [DamageZone], url: URL, log: (String) -> Void) {
        if !zones.isEmpty {
            log("Found \(zones.count) damage zone\(zones.count == 1 ? "" : "s") in \(url.lastPathComponent).")
        }
    }

    static func requiredExtension(job: StitchJob) throws -> String? {
        let settings = try job.outputSettings()
        return settings.type == .audioOnly ? nil : settings.container.fileExtension
    }
}
