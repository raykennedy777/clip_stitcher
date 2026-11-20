import Testing
import Foundation
@testable import ClipStitcher

@Suite("Field-coded copy-cut (integration)", .serialized)
struct FieldCodedCopyCutIntegrationTests {
    enum CopyCutFixture {
        enum FixtureError: Error { case absent, setupFailed(String) }

        static var capture: URL? {
            let fm = FileManager.default
            for key in ["CLIPSTITCHER_PAFF_COPYCUT_CAPTURE", "CLIPSTITCHER_PAFF_CAPTURE"] {
                if let env = ProcessInfo.processInfo.environment[key], !env.isEmpty {
                    let url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
                    if fm.fileExists(atPath: url.path) { return url }
                }
            }
            let local = folder.appendingPathComponent("source.ts")
            return fm.fileExists(atPath: local.path) ? local : nil
        }

        static let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/field-coded-copycut", isDirectory: true)

        static let slice = folder.appendingPathComponent("copycut_slice.ts")

        static let sliceStart = 60.0, sliceDuration = 300.0

        static var available: Bool {
            FileManager.default.fileExists(atPath: slice.path) || capture != nil
        }

        static func ensure() async throws -> URL {
            let fm = FileManager.default
            if fm.fileExists(atPath: slice.path) { return slice }
            guard let capture else { throw FixtureError.absent }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let ffmpeg = try FFTools.ffmpegURL()
            let result = try await ProcessRunner.run(ffmpeg, [
                "-v", "error", "-ss", String(sliceStart), "-i", capture.path,
                "-t", String(sliceDuration),
                "-map", "0:v:0", "-map", "0:a:0",
                "-c", "copy", "-y", slice.path])
            guard result.status == 0 else { throw FixtureError.absent }
            return slice
        }

        static let progressiveCompanion = folder.appendingPathComponent("prog_companion.ts")

        static func ensureProgressiveCompanion() async throws -> URL {
            let fm = FileManager.default
            if fm.fileExists(atPath: progressiveCompanion.path) { return progressiveCompanion }
            let slice = try await ensure()
            let ffmpeg = try FFTools.ffmpegURL()
            let result = try await ProcessRunner.run(ffmpeg, [
                "-v", "error", "-ss", "120", "-i", slice.path, "-t", "60",
                "-map", "0:v:0", "-vf", "yadif=0:-1:0,setsar=1",
                "-c:v", "libx264", "-preset", "veryfast", "-x264opts", "b-pyramid=none",
                "-g", "12", "-pix_fmt", "yuv420p", "-an", "-y", progressiveCompanion.path])
            guard result.status == 0 else {
                throw FixtureError.setupFailed("progressive companion encode failed")
            }
            return progressiveCompanion
        }
    }

    struct References {
        var kA: Int, kB1: Int, kB2: Int, kOut: Int
    }

    struct Context {
        var source: URL
        var clip: Clip
        var index: FrameIndex
        var containerStart: Double
        var leadingCounts: [Int?]
        var references: References?
        var trimA: (inFrame: Int, outFrame: Int)
        var trimB: (inFrame: Int, outFrame: Int)
        var sourcePackets: [Packet]
    }

    static let context = Task { try await makeContext() }

    static func makeContext() async throws -> Context {
        let source = try await CopyCutFixture.ensure()
        let probe = try await MediaProbe.probe(url: source)
        guard let video = probe.video else {
            throw CopyCutFixture.FixtureError.setupFailed("no video stream probed")
        }
        let scan = try await FrameIndexer.scanAllStreams(url: source)
        let containerStart = await MediaProbe.containerStartTime(url: source)
        let fieldCoded = FieldCodingDetector.isFieldCoded(
            packetPts: scan.index.pts,
            frameRates: [probe.video?.frameRate, probe.videoCodecFrameRate])

        var clip = Clip(bookmark: Data(), displayName: source.lastPathComponent, video: video)
        clip.audioTracks = probe.audioTracks
        clip.duration = probe.duration
        clip.frameCount = scan.index.count
        clip.fieldCoded = fieldCoded

        let leadingCounts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: scan.index.keyframeFlags, dts: scan.index.dts)
        let references = locateReferences(index: scan.index, leadingCounts: leadingCounts)

        let n = scan.index.count
        let requests: (inA: Int, outA: Int, inB: Int, outB: Int)
        if let r = references {
            requests = (r.kA + 10, r.kB1, r.kB2, r.kOut)
        } else {
            requests = (n / 5, 2 * n / 5, 3 * n / 5, 4 * n / 5)
        }
        guard let inA = CopyCutSnapper.snapInPoint(requests.inA, leadingCounts: leadingCounts),
              let outA = CopyCutSnapper.snapOutPoint(requests.outA, leadingCounts: leadingCounts),
              let inB = CopyCutSnapper.snapInPoint(requests.inB, leadingCounts: leadingCounts),
              let outB = CopyCutSnapper.snapOutPoint(requests.outB, leadingCounts: leadingCounts),
              inA < outA, inB < outB
        else {
            throw CopyCutFixture.FixtureError.setupFailed("no snappable copy-cut boundaries in the slice")
        }

        return Context(source: source, clip: clip, index: scan.index,
                       containerStart: containerStart, leadingCounts: leadingCounts,
                       references: references,
                       trimA: (inA, outA), trimB: (inB, outB),
                       sourcePackets: try await videoPackets(url: source))
    }

    static func locateReferences(index: FrameIndex, leadingCounts: [Int?]) -> References? {
        let tolerance = 0.005
        let pts = index.pts
        let zeros = leadingCounts.indices.filter { leadingCounts[$0] == 0 }
        for a in zeros {
            for b1 in zeros where abs((pts[b1] - pts[a]) - 60.52) <= tolerance {
                for b2 in zeros where abs((pts[b2] - pts[b1]) - 1.40) <= tolerance {
                    if let kOut = leadingCounts.indices.first(where: {
                        leadingCounts[$0] == 6 && abs((pts[$0] - pts[b2]) - 120.52) <= tolerance
                    }) {
                        return References(kA: a, kB1: b1, kB2: b2, kOut: kOut)
                    }
                }
            }
        }
        return nil
    }

    static func plannedItem(clip: Clip, ctx: Context,
                            settings: OutputSettings) throws -> ExportItem {
        try ExportPlanner.planItem(
            for: ExportPlanner.ClipInput(
                clip: clip, url: ctx.source, index: ctx.index,
                containerStart: ctx.containerStart,
                audioSources: AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError),
                audioMixFilters: AudioSourceResolver.resolveMixFilters(for: clip)),
            target: nil, settings: settings)
    }

    static func runExport(items: [ExportItem], clips: [Clip],
                          settings: OutputSettings, to destination: URL) async throws {
        let audio = settings.type == .audioOnly
            ? AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: nil)
            : AudioCodecPolicy.resolveAudioCodec(targetCodec: nil, container: settings.container)
        let tracks = AudioSourceResolver.resolveOutputTracks(target: nil, clips: clips)
        try await ExportEngine.export(items: items, settings: settings,
                                      audioCodec: audio.encoder, tracks: tracks,
                                      to: destination)
    }

    static func settings(_ container: Container, type: OutputType = .videoAndAudio) -> OutputSettings {
        var s = OutputSettings()
        s.mode = .connect
        s.type = type
        s.container = container
        return s
    }

    static func trimmedClip(_ ctx: Context, trim: (inFrame: Int, outFrame: Int)) -> Clip {
        var clip = ctx.clip
        clip.inPoint = trim.inFrame
        clip.outPoint = trim.outFrame
        return clip
    }

    static func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("copycut-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    struct Packet {
        var pts: Double?
        var dts: Double?
        var size: Int
        var keyframe: Bool
    }

    static func videoPackets(url: URL) async throws -> [Packet] {
        let ffprobe = try FFTools.ffprobeURL()
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("copycut-packets-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: dump) }
        let result = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "packet=pts_time,dts_time,size,flags",
            "-of", "csv=p=0", url.path], stdoutTo: dump)
        guard result.status == 0 else {
            throw CopyCutFixture.FixtureError.setupFailed("packet probe failed on \(url.lastPathComponent)")
        }
        let text = (try? String(contentsOf: dump, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 4, let size = Int(parts[2]) else { return nil }
            return Packet(pts: Double(parts[0]), dts: Double(parts[1]),
                          size: size, keyframe: parts[3].contains("K"))
        }
    }

    static func xerrorDecodeStatus(_ url: URL) async throws -> Int32 {
        let ffmpeg = try FFTools.ffmpegURL()
        let result = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", url.path, "-f", "null", "-"])
        return result.status
    }

    static func formatName(_ url: URL) async throws -> String {
        let ffprobe = try FFTools.ffprobeURL()
        let result = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-show_entries", "format=format_name",
            "-of", "default=nokey=1:noprint_wrappers=1", url.path])
        guard result.status == 0 else { return "" }
        return (String(data: result.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sourceSpanPackets(_ ctx: Context, first: Int, last: Int) -> [Packet] {
        let lo = ctx.index.pts[first] - 1e-4, hi = ctx.index.pts[last] + 1e-4
        return ctx.sourcePackets.filter { p in
            guard let pts = p.pts else { return false }
            return pts >= lo && pts <= hi
        }
    }

    private static let skipMessage: Comment =
        "PAFF capture absent — skipping field-coded copy-cut integration test (see ADR-0023)"

    @Test(.enabled(if: CopyCutFixture.available, skipMessage))
    func snappedTrimPlansCopyOnlyAndCutsAFrameExactTsPiece() async throws {
        let ctx = try await Self.context.value

        #expect(ctx.clip.fieldCoded == true, "the slice must be field-coded (PAFF)")
        #expect(ctx.clip.video?.codec == "h264")
        #expect(FieldCodedSupport.requiresCopyOnlyCuts(
            fieldCoded: ctx.clip.fieldCoded, codec: ctx.clip.video?.codec))

        if let r = ctx.references {
            #expect(ctx.trimA.inFrame == r.kA, "in snaps to the copy-safe keyframe")
            #expect(ctx.trimA.outFrame == r.kB1 - 1, "out snaps to the frame before the next copy-safe keyframe")
            #expect(ctx.trimB.inFrame == r.kB2)
            #expect(ctx.trimB.outFrame == r.kOut - 6 - 1, "out snaps past the open-GOP keyframe's 6 leading fields")
        }

        let clip = Self.trimmedClip(ctx, trim: ctx.trimA)
        let item = try Self.plannedItem(clip: clip, ctx: ctx, settings: Self.settings(.mkv))

        #expect(item.fieldCoded)
        #expect(item.segments.allSatisfy { $0.kind == .copy })
        let segment = try #require(item.segments.first)
        #expect(item.segments.count == 1)
        #expect(segment.range == ctx.trimA.inFrame..<(ctx.trimA.outFrame + 1))
        if ctx.references != nil {
            #expect(segment.range.count == 3026, "piece A is exactly the validated 3026 field packets")
        }

        let pieceExt = ExportEngine.pieceExtension(
            container: "mkv", fieldCoded: item.fieldCoded, plan: item.segments)
        #expect(pieceExt == "ts")

        let work = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let ffmpeg = try FFTools.ffmpegURL()
        let piece = try await BoundaryReencodeEngine.produceVideoPiece(
            ffmpeg, source: item.source, plan: item.segments, index: item.index,
            encoder: item.encoder, work: work, ext: pieceExt, clipIndex: 0,
            codec: item.codec, trackTimescale: nil,
            containerStart: item.containerStart, frameRate: item.frameRate,
            sourceDamaged: item.sourceDamaged, fieldCoded: item.fieldCoded)
        #expect(piece.pathExtension == "ts")

        let packets = try await Self.videoPackets(url: piece)
        #expect(packets.count == segment.range.count,
                "piece packet count must equal the planned field span exactly")
        #expect(packets.count % 2 == 0, "an odd count would mean a split field pair")

        let first = try #require(packets.first)
        #expect(first.keyframe)
        let sourceSpan = Self.sourceSpanPackets(ctx, first: ctx.trimA.inFrame, last: ctx.trimA.outFrame)
        #expect(first.size == sourceSpan.first?.size,
                "first piece packet must be the boundary keyframe field")

        #expect(packets.map(\.size).sorted() == sourceSpan.map(\.size).sorted())
    }

    @Test(.enabled(if: CopyCutFixture.available, skipMessage))
    func allThreeContainerFinalsDecodeClean() async throws {
        let ctx = try await Self.context.value
        let out = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: out) }

        for (container, formatPrefix) in [(Container.ts, "mpegts"),
                                          (Container.mkv, "matroska"),
                                          (Container.mp4, "mov,mp4")] {
            let clip = Self.trimmedClip(ctx, trim: ctx.trimA)
            let settings = Self.settings(container)
            let item = try Self.plannedItem(clip: clip, ctx: ctx, settings: settings)
            let destination = out.appendingPathComponent("trimmed.\(container.fileExtension)")

            try await Self.runExport(items: [item], clips: [clip],
                                     settings: settings, to: destination)

            #expect(FileManager.default.fileExists(atPath: destination.path))
            let format = try await Self.formatName(destination)
            #expect(format.hasPrefix(formatPrefix),
                    "\(container.fileExtension) final probed as “\(format)”")
            let decodeStatus = try await Self.xerrorDecodeStatus(destination)
            #expect(decodeStatus == 0,
                    "\(container.fileExtension) final failed the -xerror decode")

            let packets = try await Self.videoPackets(url: destination)
            #expect(packets.count == ctx.trimA.outFrame + 1 - ctx.trimA.inFrame,
                    "\(container.fileExtension) final must carry the exact field span")
            if container == .mkv {
                let pts = packets.compactMap(\.pts).sorted()
                let hasDuplicate = zip(pts, pts.dropFirst()).contains { $1 - $0 <= 0 }
                #expect(!hasDuplicate, "MKV final has duplicate video PTS")
            }
        }
    }

    @Test(.enabled(if: CopyCutFixture.available, skipMessage))
    func videoOnlyExportRewrapsTheTsPieceIntoTheContainer() async throws {
        let ctx = try await Self.context.value
        let out = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: out) }

        let clip = Self.trimmedClip(ctx, trim: ctx.trimA)
        let settings = Self.settings(.mkv, type: .videoOnly)
        let item = try Self.plannedItem(clip: clip, ctx: ctx, settings: settings)
        let destination = out.appendingPathComponent("video-only.mkv")

        try await Self.runExport(items: [item], clips: [clip],
                                 settings: settings, to: destination)

        let format = try await Self.formatName(destination)
        #expect(format.hasPrefix("matroska"), "video-only final probed as “\(format)”")
        let decodeStatus = try await Self.xerrorDecodeStatus(destination)
        #expect(decodeStatus == 0)

        let packets = try await Self.videoPackets(url: destination)
        #expect(packets.count == ctx.trimA.outFrame + 1 - ctx.trimA.inFrame)
        let pts = packets.compactMap(\.pts).sorted()
        #expect(!zip(pts, pts.dropFirst()).contains { $1 - $0 <= 0 },
                "rewrapped MKV final has duplicate video PTS")
    }

    @Test(.enabled(if: CopyCutFixture.available, skipMessage))
    func fieldCodedEntriesCarryNoDurationDirective() async throws {
        let ctx = try await Self.context.value
        let settings = Self.settings(.ts)
        let itemA = try Self.plannedItem(clip: Self.trimmedClip(ctx, trim: ctx.trimA),
                                         ctx: ctx, settings: settings)
        let itemB = try Self.plannedItem(clip: Self.trimmedClip(ctx, trim: ctx.trimB),
                                         ctx: ctx, settings: settings)

        let durations = ExportEngine.crossClipDurations(items: [itemA, itemB])
        #expect(durations == [nil, nil])

        let list = ExportEngine.concatListContents(
            pieces: [URL(fileURLWithPath: "/tmp/a.ts"), URL(fileURLWithPath: "/tmp/b.ts")],
            durations: durations)
        #expect(!list.contains("duration"))
    }

    @Test(.enabled(if: CopyCutFixture.available, skipMessage))
    func twoPieceJoinIsSeamlessAtAOneFieldStep() async throws {
        let ctx = try await Self.context.value
        let out = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: out) }

        let clipA = Self.trimmedClip(ctx, trim: ctx.trimA)
        let clipB = Self.trimmedClip(ctx, trim: ctx.trimB)
        let settings = Self.settings(.ts, type: .videoOnly)
        let itemA = try Self.plannedItem(clip: clipA, ctx: ctx, settings: settings)
        let itemB = try Self.plannedItem(clip: clipB, ctx: ctx, settings: settings)
        let destination = out.appendingPathComponent("joined.ts")

        try await Self.runExport(items: [itemA, itemB], clips: [clipA, clipB],
                                 settings: settings, to: destination)

        let decodeStatus = try await Self.xerrorDecodeStatus(destination)
        #expect(decodeStatus == 0, "joined TS failed the -xerror decode")

        let packets = try await Self.videoPackets(url: destination)
        let spanA = ctx.trimA.outFrame + 1 - ctx.trimA.inFrame
        let spanB = ctx.trimB.outFrame + 1 - ctx.trimB.inFrame
        #expect(packets.count == spanA + spanB)
        if ctx.references != nil {
            #expect(packets.count == 9046, "the validated 3026 + 6020 join")
        }

        let pts = packets.compactMap(\.pts).sorted()
        #expect(pts.count == packets.count, "every joined packet must carry a pts")
        let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }
        let field = deltas.sorted()[deltas.count / 2]
        #expect(!deltas.contains { $0 >= field * 1.5 }, "a display gap opened at the seam")
        #expect(!deltas.contains { $0 <= field * 0.5 }, "duplicate presentation timestamps")

        let dts = packets.compactMap(\.dts)
        #expect(dts.count == packets.count)
        #expect(!zip(dts, dts.dropFirst()).contains { $1 <= $0 }, "DTS not strictly monotonic")
    }

    @Test(.enabled(if: CopyCutFixture.available, skipMessage))
    func mixedJoinFieldCodedThenProgressiveExportsCleanMkv() async throws {
        let ctx = try await Self.context.value
        let companion = try await CopyCutFixture.ensureProgressiveCompanion()

        let probe = try await MediaProbe.probe(url: companion)
        let video = try #require(probe.video)
        let scan = try await FrameIndexer.scanAllStreams(url: companion)
        let companionStart = await MediaProbe.containerStartTime(url: companion)
        let companionFieldCoded = FieldCodingDetector.isFieldCoded(
            packetPts: scan.index.pts,
            frameRates: [probe.video?.frameRate, probe.videoCodecFrameRate])
        #expect(!companionFieldCoded, "the companion must probe progressive")
        var progClip = Clip(bookmark: Data(), displayName: companion.lastPathComponent, video: video)
        progClip.audioTracks = probe.audioTracks
        progClip.duration = probe.duration
        progClip.frameCount = scan.index.count
        progClip.fieldCoded = companionFieldCoded

        let settings = Self.settings(.mkv, type: .videoOnly)
        let fcClip = Self.trimmedClip(ctx, trim: ctx.trimA)
        let fcItem = try Self.plannedItem(clip: fcClip, ctx: ctx, settings: settings)
        let progItem = try ExportPlanner.planItem(
            for: ExportPlanner.ClipInput(
                clip: progClip, url: companion, index: scan.index,
                containerStart: companionStart,
                audioSources: AudioSourceResolver.resolveSources(for: progClip, missingExternal: .throwError),
                audioMixFilters: AudioSourceResolver.resolveMixFilters(for: progClip)),
            target: nil, settings: settings)
        #expect(fcItem.fieldCoded)
        #expect(!progItem.fieldCoded)

        #expect(ExportEngine.pieceExtensions(container: "mkv", mode: .connect,
                                             items: [fcItem, progItem]) == ["ts", "ts"])
        #expect(ExportEngine.crossClipDurations(items: [fcItem, progItem]) == [nil, nil])

        let out = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: out) }
        let destination = out.appendingPathComponent("mixed.mkv")
        try await Self.runExport(items: [fcItem, progItem], clips: [fcClip, progClip],
                                 settings: settings, to: destination)

        let format = try await Self.formatName(destination)
        #expect(format.hasPrefix("matroska"), "mixed join probed as “\(format)”")
        let decodeStatus = try await Self.xerrorDecodeStatus(destination)
        #expect(decodeStatus == 0, "mixed MKV join failed the -xerror decode")

        let packets = try await Self.videoPackets(url: destination)
        let spanA = ctx.trimA.outFrame + 1 - ctx.trimA.inFrame
        #expect(packets.count == spanA + scan.index.count,
                "mixed join must carry the exact field span plus every companion frame")
        let pts = packets.compactMap(\.pts).sorted()
        #expect(!zip(pts, pts.dropFirst()).contains { $1 - $0 <= 0 },
                "mixed MKV join has duplicate video PTS")
    }

    @Test(.enabled(if: CopyCutFixture.available, skipMessage))
    func wholeClipNoTrimExportStaysOnThePlainRemuxPath() async throws {
        let ctx = try await Self.context.value
        let out = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: out) }

        let clip = ctx.clip
        let settings = Self.settings(.ts, type: .videoOnly)
        let item = try Self.plannedItem(clip: clip, ctx: ctx, settings: settings)

        #expect(item.segments == [PlannedSegment(kind: .copy, range: 0..<ctx.index.count)])
        #expect(ExportEngine.pieceExtension(
            container: "mkv", fieldCoded: item.fieldCoded, plan: item.segments) == "mkv")

        let destination = out.appendingPathComponent("whole.ts")
        try await Self.runExport(items: [item], clips: [clip],
                                 settings: settings, to: destination)

        let outCount = try await FrameIndexer.frameCount(url: destination)
        let sourceCount = try await FrameIndexer.frameCount(url: ctx.source)
        #expect(outCount == sourceCount,
                "whole-clip export must carry every source video packet (remux, not cut)")
    }
}
