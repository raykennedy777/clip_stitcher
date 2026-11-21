import Foundation

enum BoundaryReencodeEngine {
    // ADR-0009
    static func reencodeVideoArgs(
        codec: String?, profile: String? = nil, pixelFormat: String?, fieldOrder: String?,
        bitrate: Int? = nil
    ) -> [String] {
        let pixFmt = pixelFormat ?? "yuv420p"
        var args = ["-c:v", EncoderSelection.encoder(for: codec), "-pix_fmt", pixFmt]
        if let p = EncoderSelection.encoderProfile(profile, codec: EncoderSelection.profileCodec(for: codec)) {
            args += ["-profile:v", p]
        }
        var fieldFilter: [String] = []
        if interlaceCapable(codec), let filter = fieldOrderFilter(fieldOrder) {
            args += ["-flags", "+ildct+ilme"]
            fieldFilter = ["-vf", filter]
        }
        return args + rateControlArgs(codec: codec, bitrate: bitrate) + fieldFilter
    }

    static let reencodeCrf = 18

    static let reencodeMpeg2Quantiser = 2

    static let reencodeBitrateHeadroom = 1.25

    static func rateControlArgs(codec: String?, bitrate: Int?) -> [String] {
        guard codec == "mpeg2video" else { return ["-crf", String(reencodeCrf)] }
        guard let bitrate, bitrate > 0 else { return ["-q:v", String(reencodeMpeg2Quantiser)] }
        let target = Int((Double(bitrate) * reencodeBitrateHeadroom).rounded())
        return ["-b:v", String(target),
                "-maxrate", String(target * 3 / 2),
                "-bufsize", String(target * 2)]
    }

    // ADR-0022
    static func mbaffRepairVideoArgs(fieldOrder: String?) -> [String] {
        let filter = fieldOrderFilter(fieldOrder) ?? topFirstScanFilter
        return [
            "-c:v", "libx264", "-flags", "+ildct+ilme",
            "-preset", "medium", "-crf", "18", "-forced-idr", "1",
            "-x264-params", "ref=5:keyint=25:scenecut=0:open_gop=0:b-pyramid=0:level=4.0",
            "-vf", filter,
        ]
    }

    static func interlaceCapable(_ codec: String?) -> Bool {
        codec == "mpeg2video" || codec == "h264"
    }

    static func fieldOrderFilter(_ fieldOrder: String?) -> String? {
        switch fieldOrder {
        case "tt", "tb": return "setparams=field_mode=tff"
        case "bb", "bt": return "setparams=field_mode=bff"
        default: return nil
        }
    }

    static let topFirstScanFilter = "setparams=field_mode=tff"

    // ADR-0009
    static func splitVideoFilter(_ encoder: [String]) -> (filter: String?, args: [String]) {
        guard let i = encoder.firstIndex(of: "-vf"), i + 1 < encoder.count else {
            return (nil, encoder)
        }
        var args = encoder
        let filter = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return (filter, args)
    }

    private static func merged(_ chain: String, _ filter: String?) -> String {
        filter.map { "\(chain),\($0)" } ?? chain
    }

    static func reencodeSegmentArguments(
        source: URL, range: Range<Int>, index: FrameIndex, encoder: [String], output: URL,
        trackTimescale: Int? = nil
    ) -> [String] {
        let anchor = index.keyframeIndex(atOrBefore: range.lowerBound) ?? 0
        let startOffset = index.pts.first ?? 0
        let seek = index.pts[anchor] - startOffset
        let relStart = range.lowerBound - anchor
        let relEnd = range.upperBound - 1 - anchor
        let (fieldFilter, encoderArgs) = splitVideoFilter(encoder)
        var args = ["-v", "error", "-ss", ExportEngine.timeString(seek), "-i", source.path]
        args += ["-vf", merged("select='between(n\\,\(relStart)\\,\(relEnd))',setpts=PTS-STARTPTS",
                               fieldFilter)]
        args += encoderArgs
        args += ["-bsf:v", ExportEngine.parameterSetRepeatFilter]
        if let trackTimescale, output.pathExtension.lowercased() == "mp4" {
            args += ["-video_track_timescale", String(trackTimescale)]
        }
        args += ["-frames:v", String(range.count), "-an", output.path]
        return args
    }

    static func repairedSegmentArguments(
        source: URL, range: Range<Int>, index: FrameIndex, zones: [DamageZone],
        containerStart: Double, frameRate: String, encoder: [String], output: URL,
        trackTimescale: Int? = nil
    ) -> [String] {
        let fps = ConformEngine.frameRateValue(frameRate) ?? 25
        let interval = 1 / fps
        let quarter = interval / 4
        let anchor = repairAnchor(source: source, range: range, index: index)
        let seek = max(0, index.pts[anchor] - containerStart)
        let spanStart = index.pts[range.lowerBound] - containerStart
        let spanEnd = segmentEndTime(range: range, index: index, frameDuration: interval)
            - containerStart

        var select = "between(t\\,\(ExportEngine.timeString(spanStart - seek - quarter))"
            + "\\,\(ExportEngine.timeString(spanEnd - interval - seek + quarter)))"
        for zone in zones {
            let windowStart = max(zone.start - quarter, spanStart + interval - quarter)
            select += "*not(between(t\\,\(ExportEngine.timeString(windowStart - seek))"
                + "\\,\(ExportEngine.timeString(zone.end - seek + quarter))))"
        }

        var args = ["-v", "error", "-ss", ExportEngine.timeString(seek)]
        args += ["-t", ExportEngine.timeString(spanEnd - (index.pts[anchor] - containerStart) + 1.0)]
        args += ["-i", source.path]
        let (fieldFilter, encoderArgs) = splitVideoFilter(encoder)
        args += ["-vf", merged("select='\(select)',setpts=PTS-STARTPTS,fps="
                               + ConformEngine.fpsToken(frameRate, double: false), fieldFilter)]
        args += encoderArgs
        args += ["-bsf:v", ExportEngine.parameterSetRepeatFilter]
        if let trackTimescale, output.pathExtension.lowercased() == "mp4" {
            args += ["-video_track_timescale", String(trackTimescale)]
        }
        args += ["-frames:v", String(trimmedSlotBudget(range: range, index: index, zones: zones,
                                                        fps: fps, containerStart: containerStart)),
                 "-an", output.path]
        return args
    }

    static func trimmedSlotBudget(range: Range<Int>, index: FrameIndex, zones: [DamageZone],
                                  fps: Double, containerStart: Double) -> Int {
        let full = slotBudget(range: range, index: index, fps: fps)
        guard range.upperBound == index.count else { return full }
        let interval = 1 / fps
        let spanStart = index.pts[range.lowerBound] - containerStart
        let spanEnd = segmentEndTime(range: range, index: index, frameDuration: interval) - containerStart
        guard let cut = zones
            .filter({ $0.affectsVideo && $0.start < spanEnd && $0.end >= spanEnd - interval })
            .map(\.start).min() else { return full }
        return max(1, min(full, Int(((cut - spanStart) * fps).rounded())))
    }

    static func repairedSegmentExpectation(
        range: Range<Int>, index: FrameIndex, zones: [DamageZone],
        containerStart: Double, frameRate: String
    ) -> (frames: Int, shortfallAllowance: Int) {
        let fps = ConformEngine.frameRateValue(frameRate) ?? 25
        let interval = 1 / fps
        let budget = trimmedSlotBudget(range: range, index: index, zones: zones,
                                       fps: fps, containerStart: containerStart)
        guard range.upperBound == index.count else { return (budget, 0) }
        let spanStart = index.pts[range.lowerBound] - containerStart
        let spanEnd = segmentEndTime(range: range, index: index, frameDuration: interval)
            - containerStart
        let windows = zones.map { zone in
            (start: max(zone.start - interval / 4, spanStart + interval * 0.75),
             end: zone.end + interval / 4)
        }
        guard let trailing = windows.filter({ $0.end >= spanEnd - interval }).map(\.start).min()
        else { return (budget, 0) }
        var lastKept = spanStart
        for i in range {
            let t = index.pts[i] - containerStart
            if t < trailing, !windows.contains(where: { t >= $0.start && t <= $0.end }) {
                lastKept = max(lastKept, t)
            }
        }
        let guaranteed = Int(((lastKept - spanStart) * fps).rounded()) + 1
        return (budget, max(0, budget - guaranteed))
    }

    private static func segmentEndTime(range: Range<Int>, index: FrameIndex,
                                       frameDuration: Double) -> Double {
        range.upperBound < index.count
            ? index.pts[range.upperBound]
            : (index.pts.last ?? 0) + frameDuration
    }

    private static func slotBudget(range: Range<Int>, index: FrameIndex, fps: Double) -> Int {
        let start = index.pts[range.lowerBound]
        let end = segmentEndTime(range: range, index: index, frameDuration: 1 / fps)
        return max(1, Int(((end - start) * fps).rounded()))
    }

    private static func repairAnchor(source: URL, range: Range<Int>, index: FrameIndex) -> Int {
        let psExtensions = ["mpg", "mpeg", "vob"]
        let back = psExtensions.contains(source.pathExtension.lowercased()) ? 2 : 1
        var anchor = index.keyframeIndex(atOrBefore: range.lowerBound) ?? 0
        for _ in 0..<back {
            anchor = index.keyframeIndex(atOrBefore: max(0, anchor - 1)) ?? 0
        }
        return anchor
    }

    static func timescaleProbeArguments(source: URL, output: URL) -> [String] {
        ["-v", "error", "-i", source.path, "-map", "0:v:0",
         "-c", "copy", "-frames:v", "1", output.path]
    }

    static func trackTimescale(timeBase: String?) -> Int? {
        let cleaned = (timeBase ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ", \n"))
        let parts = cleaned.split(separator: "/")
        guard parts.count == 2, parts[0] == "1",
              let den = Int(parts[1]), den > 0 else { return nil }
        return den
    }

    enum CopyStrategy {
        case segmentMux
        case boundedKeyframe
    }

    static func boundedCopyArguments(
        source: URL, range: Range<Int>, index: FrameIndex, containerStart: Double,
        segmentPattern: String, bitstreamFilter: [String] = [], inputFlags: [String] = []
    ) -> [String] {
        let lo = range.lowerBound, hi = range.upperBound
        let seek = max(0, index.pts[lo] - containerStart)
        let spanEnd = hi < index.pts.count ? index.pts[hi] : (index.pts.last ?? index.pts[lo])
        let span = max(0, spanEnd - index.pts[lo])
        var args = ["-v", "error"]
        args += inputFlags
        args += ["-ss", ExportEngine.timeString(seek), "-i", source.path]
        args += ["-map", "0:v:0", "-c", "copy"]
        args += bitstreamFilter
        args += ["-f", "segment"]
        args += ["-segment_frames", String(hi - lo), "-reset_timestamps", "1"]
        args += ["-t", ExportEngine.timeString(span + 2.0), segmentPattern]
        return args
    }

    static func segmentMuxExpectedSeconds(plan: SegmentPlan, sourceSpan: Double?,
                                          headSeek: ExportEngine.CopyHeadSeek? = nil) -> Double? {
        let origin = headSeek?.origin ?? 0
        guard let out = plan.outSegmentTime else { return sourceSpan.map { $0 - origin } }
        let bounded = out + ExportEngine.copyReadMargin
        return (sourceSpan.map { min(bounded, $0) } ?? bounded) - origin
    }

    static func landingProbeArguments(source: URL, seek: Double, output: URL) -> [String] {
        ["-v", "error",
         "-ss", ExportEngine.timeString(seek), "-copyts",
         "-i", source.path, "-map", "0:v:0", "-c", "copy", "-frames:v", "1",
         "-f", "nut", output.path]
    }

    // ADR-0027
    static func copyHeadSeek(
        _ ffmpeg: URL, source: URL, plan: SegmentPlan, index: FrameIndex,
        containerStart: Double, probeOutput: URL
    ) async -> ExportEngine.CopyHeadSeek? {
        guard let inCut = plan.inSegmentTime,
              let seek = ExportEngine.copyHeadSeekTarget(
                  plan: plan, index: index, containerStart: containerStart),
              let startOffset = index.pts.first
        else { return nil }
        defer { try? FileManager.default.removeItem(at: probeOutput) }
        guard let result = try? await ProcessRunner.run(
                  ffmpeg, landingProbeArguments(source: source, seek: seek, output: probeOutput)),
              result.status == 0,
              let probed = try? await FrameIndexer.buildIndex(url: probeOutput),
              let landing = probed.pts.first
        else { return nil }
        let origin = landing - startOffset
        guard origin < inCut else { return nil }
        return ExportEngine.CopyHeadSeek(seek: seek, origin: origin)
    }

    // ADR-0032
    static func sourceCarriesInBandParameterSets(
        _ ffmpeg: URL, source: URL, copyStart: Double, codec: String?, traceOutput: URL
    ) async -> Bool {
        guard let args = ExportEngine.inBandParameterSetProbeArguments(
            source: source, seek: max(0, copyStart), codec: codec) else { return false }
        defer { try? FileManager.default.removeItem(at: traceOutput) }
        guard let result = try? await ProcessRunner.run(ffmpeg, args, stderrTo: traceOutput),
              result.status == 0,
              let trace = try? String(contentsOf: traceOutput, encoding: .utf8)
        else { return false }
        return ExportEngine.tracesInBandParameterSets(trace)
    }

    static func copySegmentPlan(
        copyRange: Range<Int>, outCutKeyframe: Int?, index: FrameIndex
    ) -> SegmentPlan {
        let needsInCut = copyRange.lowerBound > 0
        return SegmentPlan(
            inFrame: copyRange.lowerBound,
            outFrame: copyRange.upperBound,
            inSegmentTime: needsInCut ? index.segmentTime(forCutAt: copyRange.lowerBound) : nil,
            outSegmentTime: outCutKeyframe.map { index.segmentTime(forCutAt: $0) }
        )
    }

    static func produceVideoPiece(
        _ ffmpeg: URL, source: URL, plan: [PlannedSegment], index: FrameIndex,
        encoder: [String], work: URL, ext: String, clipIndex: Int, displayName: String = "",
        codec: String? = nil,
        trackTimescale: Int? = nil, containerStart: Double = 0, frameRate: String? = nil,
        sourceDamaged: Bool = false, copyStrategy: CopyStrategy = .segmentMux,
        fieldCoded: Bool = false, reorderDepth: Int? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
        log: (String) -> Void = { _ in },
        pieceCache: PieceCache? = nil,
        inPointSplice: Bool = true
    ) async throws -> URL {
        guard !plan.isEmpty else { throw ExportError.invalidPlan }
        // ADR-0038
        let splices = plan.contains { $0.droppedLeadingPictures > 0 } && inPointSplice
        guard !splices || copyStrategy == .segmentMux else { throw ExportError.invalidPlan }
        let encoder = reorderDepth.map {
            EncoderSelection.withEncoderParams(
                EncoderSelection.reorderDepthParams(depth: $0, forCodec: codec),
                in: encoder, forCodec: codec)
        } ?? encoder
        let parsedRate: String? = (frameRate.map { ConformEngine.frameRateValue($0) != nil } ?? false)
            ? frameRate : nil
        guard plan.allSatisfy({ $0.damage.isEmpty }) || parsedRate != nil else {
            throw ExportError.invalidPlan
        }
        let repairRate = parsedRate ?? "25/1"
        let damagedSource = sourceDamaged || plan.contains { !$0.damage.isEmpty }
        var copyFilters: [Int: [String]] = [:]
        for (s, segment) in plan.enumerated() where segment.kind == .copy {
            var inBandParameterSets = false
            if !damagedSource, segment.range.lowerBound < index.pts.count {
                inBandParameterSets = await sourceCarriesInBandParameterSets(
                    ffmpeg, source: source,
                    copyStart: index.pts[segment.range.lowerBound] - containerStart, codec: codec,
                    traceOutput: work.appendingPathComponent("c\(clipIndex)_s\(s)_pstrace.txt"))
            }
            copyFilters[s] = ExportEngine.copyPieceBitstreamFilter(
                codec: codec, ext: ext, damaged: damagedSource,
                inBandParameterSets: inBandParameterSets)
        }
        let copyInputFlags = ExportEngine.ptsRefillInputFlags(
            codec: codec, ext: ext, damaged: damagedSource)

        let copyTimescale: Int? = ext.lowercased() == "mp4" ? trackTimescale : nil
        var pieceTimescale: Int? = copyTimescale
        if pieceTimescale == nil,
           ext.lowercased() == "mp4",
           plan.contains(where: { $0.kind == .copy }),
           plan.contains(where: { $0.kind == .reEncode }) {
            let probe = work.appendingPathComponent("c\(clipIndex)_tsprobe.mp4")
            try await run(ffmpeg, timescaleProbeArguments(source: source, output: probe))
            pieceTimescale = Self.trackTimescale(timeBase: await MediaProbe.videoTimeBase(url: probe))
        }

        let segmentFrames = plan.map { $0.range.count }
        let interval = meanFrameInterval(index)
        let sourceSpan = interval.flatMap { i in
            index.pts.last.map { $0 - index.pts[0] + i }
        }

        var pieces: [URL] = []
        var pendingStores: [(key: String, piece: URL)] = []
        var hitKeys: [String] = []
        for (s, segment) in plan.enumerated() {
            var bsf = copyFilters[s] ?? []
            let copyPlan: SegmentPlan? = segment.kind == .copy && copyStrategy == .segmentMux
                ? copySegmentPlan(copyRange: segment.range,
                                  outCutKeyframe: segment.outCutKeyframe, index: index)
                : nil
            var headSeek: ExportEngine.CopyHeadSeek?
            if let copyPlan, ExportEngine.needsCut(copyPlan) {
                headSeek = await Self.copyHeadSeek(
                    ffmpeg, source: source, plan: copyPlan, index: index,
                    containerStart: containerStart,
                    probeOutput: work.appendingPathComponent("c\(clipIndex)_s\(s)_seek.nut"))
            }
            // ADR-0038
            let spliced = segment.kind == .copy && segment.droppedLeadingPictures > 0 && inPointSplice
            if spliced {
                bsf = OpenGopSplice.prependingDrop(
                    OpenGopSplice.leadingPictureDropFilter(
                        keyframe: segment.range.lowerBound,
                        count: segment.droppedLeadingPictures, index: index,
                        containerStart: containerStart, seek: headSeek?.seek ?? 0),
                    to: bsf)
            }
            let expected: Double?
            switch segment.kind {
            case .reEncode: expected = interval.map { Double(segment.range.count) * $0 }
            case .copy:
                switch copyStrategy {
                case .segmentMux:
                    expected = copyPlan.flatMap {
                        segmentMuxExpectedSeconds(plan: $0, sourceSpan: sourceSpan,
                                                  headSeek: headSeek)
                    }
                case .boundedKeyframe:
                    let lo = segment.range.lowerBound, hi = segment.range.upperBound
                    expected = (lo < index.pts.count && hi < index.pts.count)
                        ? index.pts[hi] - index.pts[lo] : sourceSpan
                }
            }
            let onOutTime: @Sendable (Double) -> Void = { t in
                onProgress(ExportProgress.withinClip(
                    segmentFrames: segmentFrames, completedSegments: s,
                    currentRunFraction: ExportProgress.runFraction(outTime: t, expectedSeconds: expected)))
            }
            let segmentClock = StageClock()
            let piece: URL
            var cached = false
            switch segment.kind {
            case .reEncode where !segment.damage.isEmpty:
                piece = work.appendingPathComponent("c\(clipIndex)_s\(s)_rep.\(ext)")
                cached = try await runCached(ffmpeg, repairedSegmentArguments(
                    source: source, range: segment.range, index: index,
                    zones: segment.damage, containerStart: containerStart,
                    frameRate: repairRate, encoder: encoder, output: piece,
                    trackTimescale: pieceTimescale),
                    source: source, piece: piece, segment: segment, cache: pieceCache,
                    pendingStores: &pendingStores, hitKeys: &hitKeys, onOutTime: onOutTime)
            case .reEncode:
                piece = work.appendingPathComponent("c\(clipIndex)_s\(s)_re.\(ext)")
                cached = try await runCached(ffmpeg, reencodeSegmentArguments(
                    source: source, range: segment.range, index: index,
                    encoder: encoder, output: piece, trackTimescale: pieceTimescale),
                    source: source, piece: piece, segment: segment, cache: pieceCache,
                    pendingStores: &pendingStores, hitKeys: &hitKeys, onOutTime: onOutTime)
            case .copy where copyStrategy == .boundedKeyframe:
                let pattern = work.appendingPathComponent("c\(clipIndex)_s\(s)_cp_%03d.\(ext)").path
                try await run(ffmpeg, boundedCopyArguments(
                    source: source, range: segment.range, index: index,
                    containerStart: containerStart, segmentPattern: pattern,
                    bitstreamFilter: bsf, inputFlags: copyInputFlags), onOutTime: onOutTime)
                piece = work.appendingPathComponent(String(
                    format: "c\(clipIndex)_s\(s)_cp_%03d.\(ext)", 0))
            case .copy:
                let copyPlan = copyPlan ?? copySegmentPlan(
                    copyRange: segment.range, outCutKeyframe: segment.outCutKeyframe, index: index)
                if ExportEngine.needsCut(copyPlan) {
                    let pattern = work.appendingPathComponent("c\(clipIndex)_s\(s)_cp_%03d.\(ext)").path
                    try await run(ffmpeg, ExportEngine.cutArguments(
                        source: source, plan: copyPlan, segmentPattern: pattern,
                        bitstreamFilter: bsf, trackTimescale: copyTimescale,
                        headSeek: headSeek, inputFlags: copyInputFlags), onOutTime: onOutTime)
                    piece = work.appendingPathComponent(String(
                        format: "c\(clipIndex)_s\(s)_cp_%03d.\(ext)",
                        ExportEngine.wantedSegmentIndex(plan: copyPlan)))
                    discardDeadSegments(prefix: "c\(clipIndex)_s\(s)_cp_", keeping: piece, in: work)
                } else {
                    piece = work.appendingPathComponent("c\(clipIndex)_s\(s)_cp.\(ext)")
                    try await run(ffmpeg, ExportEngine.remuxArguments(
                        source: source, output: piece, bitstreamFilter: bsf,
                        trackTimescale: copyTimescale, inputFlags: copyInputFlags),
                                  onOutTime: onOutTime)
                }
            }
            guard FileManager.default.fileExists(atPath: piece.path) else {
                throw ExportError.missingSegment
            }
            if spliced {
                // ADR-0038
                try await OpenGopSplice.rewriteFirstIrapToBLA(try FFTools.ffprobeURL(), piece: piece)
            }
            log(segmentTimingLine(clipIndex: clipIndex, segment: s, planned: segment,
                                  seconds: segmentClock.seconds, cached: cached))
            pieces.append(piece)
            onProgress(ExportProgress.withinClip(
                segmentFrames: segmentFrames, completedSegments: s + 1, currentRunFraction: 0))
        }

        let result: URL
        if pieces.count == 1 {
            result = pieces[0]
        } else {
            let joined = work.appendingPathComponent("c\(clipIndex)_joined.\(ext)")
            let listFile = work.appendingPathComponent("c\(clipIndex)_concat.txt")
            let durations = fieldCoded ? [] : segmentSpans(plan, index: index)
            try ExportEngine.concatListContents(pieces: pieces, durations: durations)
                .write(to: listFile, atomically: true, encoding: .utf8)
            let concatClock = StageClock()
            try await run(ffmpeg, ExportEngine.concatArguments(listFile: listFile, output: joined))
            log("clip \(clipIndex) concat: \(concatClock.label)")
            result = joined
        }
        let verifyClock = StageClock()
        let location = VerificationLocation(
            clipIndex: clipIndex, displayName: displayName,
            piece: result.lastPathComponent, plan: plan)
        func evictHits() { for key in hitKeys { pieceCache?.evict(key, ext: ext) } }
        if fieldCoded {
            do { try await verifyFieldCodedPiece(ffmpeg, result, at: location) } catch {
                evictHits()
                throw error
            }
            log("clip \(clipIndex) verify: \(verifyClock.label)")
            for entry in pendingStores { pieceCache?.store(entry.key, from: entry.piece) }
            return result
        }
        var outputCounts: [Int] = []
        var shortfallAllowance = 0
        for segment in plan {
            if segment.damage.isEmpty {
                outputCounts.append(segment.range.count)
            } else {
                let expectation = repairedSegmentExpectation(
                    range: segment.range, index: index, zones: segment.damage,
                    containerStart: containerStart, frameRate: repairRate)
                outputCounts.append(expectation.frames)
                shortfallAllowance += expectation.shortfallAllowance
            }
        }
        do {
            try await verifyPiece(ffmpeg, result, expectedCounts: outputCounts,
                                  shortfallAllowance: shortfallAllowance,
                                  sourceDamaged: sourceDamaged,
                                  plan: plan, sourcePts: index.pts, at: location)
        } catch {
            evictHits()
            throw error
        }
        log("clip \(clipIndex) verify: \(verifyClock.label)")
        for entry in pendingStores { pieceCache?.store(entry.key, from: entry.piece) }
        return result
    }

    private static func runCached(
        _ ffmpeg: URL, _ args: [String], source: URL, piece: URL, segment: PlannedSegment,
        cache: PieceCache?, pendingStores: inout [(key: String, piece: URL)],
        hitKeys: inout [String],
        onOutTime: @escaping @Sendable (Double) -> Void
    ) async throws -> Bool {
        let key = await cache?.key(source: source, arguments: args, output: piece,
                                   segment: segment, ffmpeg: ffmpeg)
        if let cache, let key, cache.fetch(key, to: piece) {
            hitKeys.append(key)
            return true
        }
        try await run(ffmpeg, args, onOutTime: onOutTime)
        if let key { pendingStores.append((key, piece)) }
        return false
    }

    static func segmentTimingLine(clipIndex: Int, segment s: Int, planned: PlannedSegment,
                                  seconds: Double, cached: Bool = false) -> String {
        let kind = planned.kind == .copy ? "copy"
            : planned.damage.isEmpty ? "reEncode" : "reEncode (repair)"
        let frames = planned.range.count
        var line = "clip \(clipIndex) s\(s) \(kind) [\(planned.range.lowerBound),\(planned.range.upperBound)): "
            + "\(StageClock.label(seconds)), \(StageClock.count(frames, "frame"))"
        if planned.droppedLeadingPictures > 0 {
            line += ", \(StageClock.count(planned.droppedLeadingPictures, "leading picture")) dropped"
        }
        if cached {
            line += ", piece cache hit"
        } else if planned.kind == .reEncode,
                  let fps = StageClock.fpsLabel(frames: frames, seconds: seconds) {
            line += ", \(fps)"
        }
        return line
    }

    static func expectedFrameCount(_ plan: [PlannedSegment]) -> Int {
        plan.reduce(0) { $0 + $1.range.count }
    }

    static func segmentSpans(_ plan: [PlannedSegment], index: FrameIndex) -> [Double?] {
        plan.map { seg in
            let lo = seg.range.lowerBound, hi = seg.range.upperBound
            guard lo < index.pts.count, hi < index.pts.count else { return nil }
            return index.pts[hi] - index.pts[lo]
        }
    }

    // ADR-0030
    static func verifyWindows(
        plan: [PlannedSegment], outputCounts: [Int],
        pieceKeyframePts: [Int: Double], pieceCopySafeFlags: [Int: Bool],
        pieceSpan: ClosedRange<Double>
    ) -> [ClosedRange<Double>]? {
        guard !plan.isEmpty, plan.count == outputCounts.count,
              pieceSpan.upperBound > pieceSpan.lowerBound else { return nil }
        var segmentStarts: [Int] = []
        var offset = 0
        for count in outputCounts { segmentStarts.append(offset); offset += count }
        let total = offset
        let keyframes = pieceKeyframePts.keys.sorted()

        func secondKeyframe(from lo: Int, below hi: Int) -> Double? {
            let inside = keyframes.filter { $0 >= lo && $0 < hi }
            return inside.count > 1 ? pieceKeyframePts[inside[1]] : nil
        }
        func windowStart(before seam: Int, inCopyFrom copyStart: Int) -> Double {
            guard let lastBefore = keyframes.last(where: { $0 < seam && $0 >= copyStart }),
                  let safe = keyframes.last(where: {
                      $0 <= lastBefore && $0 >= copyStart && pieceCopySafeFlags[$0] == true
                  }), let pts = pieceKeyframePts[safe]
            else { return pieceKeyframePts[copyStart] ?? pieceSpan.lowerBound }
            return pts
        }

        var windows: [ClosedRange<Double>] = []
        guard plan.contains(where: { $0.kind == .reEncode }) else {
            let end = secondKeyframe(from: 0, below: total) ?? pieceSpan.upperBound
            windows.append(pieceSpan.lowerBound...max(end, pieceSpan.lowerBound))
            return merged(windows, in: pieceSpan)
        }
        for (i, segment) in plan.enumerated() where segment.kind == .reEncode {
            let seam = segmentStarts[i]
            let start = (i > 0 && plan[i - 1].kind == .copy)
                ? windowStart(before: seam, inCopyFrom: segmentStarts[i - 1])
                : pieceSpan.lowerBound
            let end: Double
            if i + 1 < plan.count, plan[i + 1].kind == .copy {
                let next = segmentStarts[i + 1]
                end = secondKeyframe(from: next, below: next + outputCounts[i + 1])
                    ?? pieceSpan.upperBound
            } else {
                end = pieceSpan.upperBound
            }
            windows.append(min(start, end)...max(start, end))
        }
        return merged(windows, in: pieceSpan)
    }

    private static func merged(_ windows: [ClosedRange<Double>],
                               in span: ClosedRange<Double>) -> [ClosedRange<Double>]? {
        var joined: [ClosedRange<Double>] = []
        for window in windows.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = joined.last, window.lowerBound <= last.upperBound {
                joined[joined.count - 1] = last.lowerBound...max(last.upperBound, window.upperBound)
            } else {
                joined.append(window)
            }
        }
        guard let only = joined.first, joined.count > 1
                || only.lowerBound > span.lowerBound || only.upperBound < span.upperBound
        else { return nil }
        return joined
    }

    // ADR-0030, ADR-0032
    static func decodeCheck(_ ffmpeg: URL, _ piece: URL, failureLabel: String,
                                   requireSilentDecode: Bool,
                                   at location: VerificationLocation,
                                   windows: [ClosedRange<Double>]? = nil,
                                   pieceStart: Double = 0,
                                   copySafeKeyframePts: [Double] = []) async throws {
        if let windows, !windows.isEmpty,
           try await boundedDecodePassed(
               ffmpeg, piece, windows: windows, pieceStart: pieceStart,
               copySafeKeyframePts: copySafeKeyframePts,
               requireSilentDecode: requireSilentDecode) {
            return
        }
        let decode = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", piece.path, "-f", "null", "-"])
        let complaints = String(data: decode.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard decode.status == 0 else {
            throw ExportError.verificationFailed(location.message(
                failureLabel,
                detail: complaints.isEmpty ? "decode exited \(decode.status)" : complaints))
        }
        guard !requireSilentDecode || complaints.isEmpty else {
            throw ExportError.verificationFailed(location.message(failureLabel, detail: complaints))
        }
    }

    static let seekTolerance = 0.001

    private static func boundedDecodePassed(
        _ ffmpeg: URL, _ piece: URL, windows: [ClosedRange<Double>], pieceStart: Double,
        copySafeKeyframePts: [Double], requireSilentDecode: Bool
    ) async throws -> Bool {
        for window in windows {
            var seekArgs: [String] = []
            var span = window.upperBound - pieceStart
            if window.lowerBound > pieceStart + seekTolerance {
                guard let entry = try await measuredEntry(
                    ffmpeg, piece, to: window.lowerBound, from: pieceStart,
                    copySafeKeyframePts: copySafeKeyframePts) else { return false }
                seekArgs = ["-ss", ExportEngine.timeString(entry.ask)]
                span = window.upperBound - entry.landing
            }
            guard span > 0 else { return false }
            let decode = try await ProcessRunner.run(
                ffmpeg, ["-v", "error", "-xerror"] + seekArgs + ["-i", piece.path]
                    + ["-t", ExportEngine.timeString(span), "-f", "null", "-"])
            let complaints = String(data: decode.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard decode.status == 0, !requireSilentDecode || complaints.isEmpty else {
                return false
            }
        }
        return true
    }

    private static func measuredEntry(
        _ ffmpeg: URL, _ piece: URL, to target: Double, from pieceStart: Double,
        copySafeKeyframePts: [Double]
    ) async throws -> (ask: Double, landing: Double)? {
        var ask = target - pieceStart
        for _ in 0..<2 {
            guard let landing = try await seekLanding(ffmpeg, piece: piece, seek: ask) else {
                return nil
            }
            if landing <= target + seekTolerance,
               copySafeKeyframePts.contains(where: { abs($0 - landing) <= seekTolerance }) {
                return (ask, landing)
            }
            ask += target - landing
            if ask < 0 { return nil }
        }
        return nil
    }

    static func seekLanding(_ ffmpeg: URL, piece: URL, seek: Double) async throws -> Double? {
        let probe = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-copyts", "-ss", ExportEngine.timeString(seek), "-i", piece.path,
            "-frames:v", "1", "-map", "0:v:0", "-c", "copy", "-f", "framecrc", "-"])
        guard probe.status == 0, let text = String(data: probe.stdout, encoding: .utf8) else {
            return nil
        }
        return framecrcFirstPts(text)
    }

    static func framecrcFirstPts(_ text: String) -> Double? {
        var timeBase: Double?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#tb ") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let ratio = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces).split(separator: "/")
                if ratio.count == 2, let n = Double(ratio[0]), let d = Double(ratio[1]), d != 0 {
                    timeBase = n / d
                }
            } else if !line.hasPrefix("#") {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count > 2, let base = timeBase,
                      let ticks = Double(fields[2].trimmingCharacters(in: .whitespaces))
                else { return nil }
                return ticks * base
            }
        }
        return nil
    }

    static func verifyPiece(_ ffmpeg: URL, _ piece: URL, expectedCounts: [Int],
                                    shortfallAllowance: Int = 0, sourceDamaged: Bool = false,
                                    plan: [PlannedSegment], sourcePts: [Double],
                                    at location: VerificationLocation) async throws {
        let expectedFrames = expectedCounts.reduce(0, +)
        let actual = try await FrameIndexer.frameCount(url: piece)
        guard actual <= expectedFrames, actual >= expectedFrames - shortfallAllowance else {
            throw ExportError.verificationFailed(location.message(
                "Produced \(actual) video frames but the cut kept \(expectedFrames)"
                + (shortfallAllowance > 0 ? " (−\(shortfallAllowance) allowed at the damaged file end)." : ".")))
        }
        var outputCounts = expectedCounts
        if actual < expectedFrames,
           let last = plan.lastIndex(where: { !$0.damage.isEmpty }) {
            outputCounts[last] -= expectedFrames - actual
        }
        let pieceIndex = try await FrameIndexer.buildIndex(url: piece)
        let pts = pieceIndex.pts
        let copySafe = CopySafeBoundaryDetector.copySafeFlags(
            keyframeFlags: pieceIndex.keyframeFlags, dts: pieceIndex.dts)
        var keyframePts: [Int: Double] = [:]
        var copySafeFlags: [Int: Bool] = [:]
        for i in pieceIndex.keyframeFlags.indices where pieceIndex.keyframeFlags[i] {
            keyframePts[i] = pts[i]
            copySafeFlags[i] = i < copySafe.count && copySafe[i]
        }
        let span = (pts.first ?? 0)...(pts.last ?? 0)
        let windows = verifyWindows(plan: plan, outputCounts: outputCounts,
                                    pieceKeyframePts: keyframePts,
                                    pieceCopySafeFlags: copySafeFlags, pieceSpan: span)
        try await decodeCheck(ffmpeg, piece, failureLabel: "A decode check failed on the cut.",
                              requireSilentDecode: !sourceDamaged
                                  && plan.allSatisfy { $0.damage.isEmpty },
                              at: location,
                              windows: windows, pieceStart: span.lowerBound,
                              copySafeKeyframePts: keyframePts.compactMap {
                                  copySafeFlags[$0.key] == true ? $0.value : nil
                              }.sorted())
        if let reason = ExportEngine.timestampDefect(pts: pts, plan: plan, sourcePts: sourcePts,
                                                     outputCounts: outputCounts) {
            throw ExportError.verificationFailed(location.message(
                "The cut produced irregular timestamps: \(reason)"))
        }
    }

    private static func verifyFieldCodedPiece(_ ffmpeg: URL, _ piece: URL,
                                              at location: VerificationLocation) async throws {
        try await decodeCheck(ffmpeg, piece, failureLabel: "A decode check failed on the repaired video.",
                              requireSilentDecode: false, at: location)
    }

    private static func meanFrameInterval(_ index: FrameIndex) -> Double? {
        let pts = index.pts
        guard pts.count >= 2 else { return nil }
        return (pts[pts.count - 1] - pts[0]) / Double(pts.count - 1)
    }

    static func discardDeadSegments(prefix: String, keeping piece: URL, in work: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: work.path) else { return }
        for name in names where name.hasPrefix(prefix) && name != piece.lastPathComponent {
            try? fm.removeItem(at: work.appendingPathComponent(name))
        }
    }

    private static func run(_ ffmpeg: URL, _ args: [String],
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
            throw ExportError.cutFailed(String(data: result.stderr, encoding: .utf8) ?? "exit \(result.status)")
        }
    }
}
