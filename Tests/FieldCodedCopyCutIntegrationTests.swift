import Testing
import Foundation
@testable import ClipStitcher

/// End-to-end regression net for the field-coded (PAFF) copy-cut export route (issue
/// #96) — the acceptance criteria the fast unit suites can't cover, because they need a
/// *real* field-coded source: the encoders on this machine are MBAFF-only, so a PAFF
/// fixture can't be synthesised. The unit suites pin the pure decisions (snapping, the
/// planner's copy-only invariant, `.ts` piece extension, directive-free concat lists);
/// this suite proves the decisions compose into frame-exact, clean-decoding files on
/// real broadcast PAFF footage, through the same `ExportPlanner.planItem` →
/// `ExportEngine.export` path the app runs.
///
/// **Owns no copyrighted bytes (ADR-0023).** It cuts a slice on demand from a
/// developer-supplied field-coded capture into a fully-gitignored folder, caches it
/// there, and **skips loudly** when neither the cached slice nor the capture is present
/// (a fresh clone / other machine). Kept out of the everyday run by living in its own
/// suite — run it on demand with
/// `-only-testing:ClipStitcherTests/FieldCodedCopyCutIntegrationTests`.
///
/// Reference data (shell de-risk of issue #96, measured on the capture this fixture is
/// cut from): copy-safe keyframes 60.52 s and then 1.40 s apart, an open-GOP keyframe
/// with 6 leading fields 120.52 s later; the spans between them are exactly **3026**
/// and **6020** field packets. `locateReferences` re-finds those keyframes in the slice
/// by that spacing signature (stream copy preserves packet structure, only absolute
/// times shift), so the absolute counts stay assertable; on a different capture the
/// signature is absent and the tests fall back to the invariant form — piece packet
/// count == the planned field span exactly, count even, first packet == the boundary
/// keyframe field.
@Suite("Field-coded copy-cut (integration)", .serialized)
struct FieldCodedCopyCutIntegrationTests {

    /// Resolves the PAFF fixture without committing any copyrighted media (ADR-0023).
    enum CopyCutFixture {
        enum FixtureError: Error { case absent, setupFailed(String) }

        /// A developer-supplied field-coded capture — copyrighted, **never committed**
        /// (ADR-0023). Point `CLIPSTITCHER_PAFF_COPYCUT_CAPTURE` (or the generic
        /// `CLIPSTITCHER_PAFF_CAPTURE` the repair test also reads) at one, or drop a
        /// file at `Tests/Fixtures/field-coded-copycut/source.ts` (the folder is fully
        /// gitignored). Absent on a fresh clone, so the suite skips loudly. Returns nil
        /// unless a capture actually exists.
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

        /// The gitignored local fixtures folder, located relative to *this source file*
        /// (`#filePath`) — neither the environment nor the working directory reaches the
        /// test runner. Distinct from the repair test's `field-coded` folder so the two
        /// fixtures can never clash.
        static let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                     // Tests/
            .appendingPathComponent("Fixtures/field-coded-copycut", isDirectory: true)

        static let slice = folder.appendingPathComponent("copycut_slice.ts")

        /// The cut recipe: a `-c copy` window that **contains the shell-validated cut
        /// coordinates** (the copy-safe keyframes at source ~120–183 s and the open-GOP
        /// out boundary at ~303 s). Stream copy preserves the exact packets and keyframe
        /// structure — only absolute timestamps shift — so the spans between the same
        /// keyframes keep their exact packet counts in the slice.
        static let sliceStart = 60.0, sliceDuration = 300.0

        /// The suite can run iff the cached slice or a developer-supplied capture exists.
        static var available: Bool {
            FileManager.default.fileExists(atPath: slice.path) || capture != nil
        }

        /// The cached slice, cut from the capture on demand (and cached in the
        /// gitignored folder) when absent. Throws `.absent` when neither exists.
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

        /// The progressive companion for the mixed-join test: ~60 s of the slice
        /// re-encoded to progressive x264 — same codec/dims/rate as the PAFF clip, the
        /// only shape the app stream-concats, with B-pyramid off matching the app's
        /// re-encode policy (ADR-0011). Synthesized (and cached in the same gitignored
        /// folder) because a mixed join needs a *real* progressive clip next to the
        /// PAFF one and no committable media exists (ADR-0023). Derived bytes of a
        /// copyrighted capture — never committed either.
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

    // MARK: - Shared context (built once per process)

    /// The shell-validated keyframes, re-located in the slice: `kA`/`kB1`/`kB2` are
    /// copy-safe (leading count 0), `kOut` is the open-GOP keyframe with 6 leading
    /// fields. Piece A = `[kA, kB1)` (3026 packets), piece B = `[kB2, kOut − 6)`
    /// (6020 packets).
    struct References {
        var kA: Int, kB1: Int, kB2: Int, kOut: Int
    }

    /// Everything every test needs, computed once: the app's own import pipeline
    /// (probe → full-stream index → field-coded cadence check → container start,
    /// mirroring `ProjectDocument.importClip`), the per-keyframe leading counts the cut
    /// editor snaps against, and the two snapped trims.
    struct Context {
        var source: URL
        /// Template clip with no in/out — tests copy it and set points.
        var clip: Clip
        var index: FrameIndex
        var containerStart: Double
        var leadingCounts: [Int?]
        /// nil when the capture isn't the shell-validated one — absolute-count
        /// assertions then degrade to the invariant form.
        var references: References?
        /// Snapped trims (inclusive in/out frames) produced by `CopyCutSnapper` over
        /// the real leading counts, exactly as the cut editor's `setIn`/`setOut` do.
        var trimA: (inFrame: Int, outFrame: Int)
        var trimB: (inFrame: Int, outFrame: Int)
        /// The slice's own video packets (pts/dts/size/keyframe), for frame-exactness
        /// comparison against produced pieces.
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

        // The snapped trims, via the same pure snapper the cut editor's setIn/setOut
        // consult. With the validated capture the requested playhead positions are
        // anchored to the located keyframes (a mid-GOP park near kA; parked *on* the
        // out keyframes — the snapper owns the k − count − 1 arithmetic); on another
        // capture, generic positions at 1/5 … 4/5 of the clip.
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

    /// Re-finds the shell-validated keyframes by their spacing signature: copy-safe
    /// keyframes 60.52 s then 1.40 s apart, with a 6-leading-field open-GOP keyframe
    /// 120.52 s after the third. Stream copy shifts absolute times uniformly, so the
    /// pairwise spacings survive the slice cut exactly. nil when the signature is
    /// absent (a different capture) — verified unique on the validated one.
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

    // MARK: - Production-shaped plumbing

    /// One clip's planned export item, constructed exactly as `ProjectDocument.export`
    /// does — through `ExportPlanner.planItem` with the shared audio resolvers — so the
    /// planner's copy-only invariant and `fieldCoded` stamping are exercised, never
    /// hand-built.
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

    /// Runs the real `ExportEngine.export`, resolving the audio codec and output
    /// tracks the way `ProjectDocument.export` does (no target clip).
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

    // MARK: - ffprobe/ffmpeg observation helpers (gate by exit code, never stderr)

    struct Packet {
        var pts: Double?
        var dts: Double?
        var size: Int
        var keyframe: Bool
    }

    /// The video stream's packets in demux (decode) order. The dump is thousands of
    /// lines, so it streams to a temp file rather than through the result pipe —
    /// `ProcessRunner.run` without `stdoutTo`/`onStdout` reads the pipe only after
    /// exit, and a dump past the pipe buffer would deadlock the probe (the same
    /// reason `FrameIndexer.buildIndex` streams to a file).
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

    /// Full-decode gate: `-xerror` exit code ONLY — recovery-point entry prints benign
    /// mmco/reference-frame warnings on stderr even at `-v error` (issue #96 de-risk).
    static func xerrorDecodeStatus(_ url: URL) async throws -> Int32 {
        let ffmpeg = try FFTools.ffmpegURL()
        let result = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", url.path, "-f", "null", "-"])
        return result.status
    }

    /// The container's ffprobe `format_name` (e.g. "mpegts", "matroska,webm").
    static func formatName(_ url: URL) async throws -> String {
        let ffprobe = try FFTools.ffprobeURL()
        let result = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-show_entries", "format=format_name",
            "-of", "default=nokey=1:noprint_wrappers=1", url.path])
        guard result.status == 0 else { return "" }
        return (String(data: result.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The source's packets whose pts lie within the inclusive frame span
    /// `[pts[first], pts[last]]` of the index — the payloads a frame-exact copy of
    /// that span must carry.
    static func sourceSpanPackets(_ ctx: Context, first: Int, last: Int) -> [Packet] {
        let lo = ctx.index.pts[first] - 1e-4, hi = ctx.index.pts[last] + 1e-4
        return ctx.sourcePackets.filter { p in
            guard let pts = p.pts else { return false }
            return pts >= lo && pts <= hi
        }
    }

    private static let skipMessage: Comment =
        "PAFF capture absent — skipping field-coded copy-cut integration test (see ADR-0023)"

    // MARK: - Tests

    /// The headline (issue #96): a snapped trim on the real PAFF capture plans **copy
    /// only** through `ExportPlanner.planItem` (fieldCoded stamped, no re-encode
    /// segment), the engine pins its piece to `.ts` whatever the container, and the
    /// piece the engine produces is **frame-exact** — packet count == the planned
    /// field span exactly (the shell-validated 3026 on this capture), count even (no
    /// split field pairs), first packet == the boundary keyframe field, and the piece
    /// carries exactly the source span's packet payloads. The piece is produced by the
    /// same `BoundaryReencodeEngine.produceVideoPiece` call the export makes (the
    /// export's own work dir is deleted before it returns, so the piece is inspected
    /// here); the same items go through the full `ExportEngine.export` in the
    /// container/join/whole-clip tests.
    @Test(.enabled(if: CopyCutFixture.available, skipMessage))
    func snappedTrimPlansCopyOnlyAndCutsAFrameExactTsPiece() async throws {
        let ctx = try await Self.context.value

        // Preconditions that make this a genuine PAFF copy-cut exercise — if any
        // fails, the fixture recipe drifted and the assertions below test nothing.
        #expect(ctx.clip.fieldCoded == true, "the slice must be field-coded (PAFF)")
        #expect(ctx.clip.video?.codec == "h264")
        #expect(FieldCodedSupport.requiresCopyOnlyCuts(
            fieldCoded: ctx.clip.fieldCoded, codec: ctx.clip.video?.codec))

        // With the validated capture, the snapped marks land exactly on the
        // shell-validated boundaries.
        if let r = ctx.references {
            #expect(ctx.trimA.inFrame == r.kA, "in snaps to the copy-safe keyframe")
            #expect(ctx.trimA.outFrame == r.kB1 - 1, "out snaps to the frame before the next copy-safe keyframe")
            #expect(ctx.trimB.inFrame == r.kB2)
            #expect(ctx.trimB.outFrame == r.kOut - 6 - 1, "out snaps past the open-GOP keyframe's 6 leading fields")
        }

        let clip = Self.trimmedClip(ctx, trim: ctx.trimA)
        let item = try Self.plannedItem(clip: clip, ctx: ctx, settings: Self.settings(.mkv))

        // Planner: fieldCoded stamped; the plan is copy-only, a single segment
        // covering exactly the snapped range (the invariant threw otherwise).
        #expect(item.fieldCoded)
        #expect(item.segments.allSatisfy { $0.kind == .copy })
        let segment = try #require(item.segments.first)
        #expect(item.segments.count == 1)
        #expect(segment.range == ctx.trimA.inFrame..<(ctx.trimA.outFrame + 1))
        if ctx.references != nil {
            #expect(segment.range.count == 3026, "piece A is exactly the validated 3026 field packets")
        }

        // Engine decision: a cut field-coded clip's piece is .ts whatever the container.
        let pieceExt = ExportEngine.pieceExtension(
            container: "mkv", fieldCoded: item.fieldCoded, plan: item.segments)
        #expect(pieceExt == "ts")

        // Produce the piece exactly as ExportEngine.export does and hold it to the
        // frame-exactness invariants.
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

        // First packet is the boundary keyframe field: keyframe-flagged, and the same
        // payload size as the source's packet at the snapped in point. (A count-0
        // keyframe is first in decode and presentation order alike.)
        let first = try #require(packets.first)
        #expect(first.keyframe)
        let sourceSpan = Self.sourceSpanPackets(ctx, first: ctx.trimA.inFrame, last: ctx.trimA.outFrame)
        #expect(first.size == sourceSpan.first?.size,
                "first piece packet must be the boundary keyframe field")

        // The piece carries exactly the source span's packet payloads — same sizes,
        // nothing dropped, duplicated, or re-encoded.
        #expect(packets.map(\.size).sorted() == sourceSpan.map(\.size).sorted())
    }

    /// The same snapped trim through the real `ExportEngine.export` into all three
    /// final containers. Each output decodes `-xerror` clean start-to-EOF (exit code
    /// only) and genuinely is its container; the MKV final — the DTS-collapse trap the
    /// `.ts` piece exists to dodge — has no duplicate video PTS.
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
                // The B-field PTS dips must not collapse onto duplicate timestamps.
                let pts = packets.compactMap(\.pts).sorted()
                let hasDuplicate = zip(pts, pts.dropFirst()).contains { $1 - $0 <= 0 }
                #expect(!hasDuplicate, "MKV final has duplicate video PTS")
            }
        }
    }

    /// A video-only export has no audio mux to rewrap the `.ts` piece into the chosen
    /// container, so the engine routes it through the one-entry concat (slice 5) — the
    /// placed file must genuinely be MKV, frame-exact, clean, and duplicate-PTS-free.
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

    /// The cross-clip concat list drops the `duration` directive **per field-coded
    /// entry** — not all-or-nothing, which would reopen the issue-#6/ADR-0008 seam gap
    /// for any progressive clip sharing the join. Every entry of this all-field-coded
    /// join is nil'd, so the written list carries no directive at all (the
    /// shell-validated form: a `.ts` piece self-reports exactly its true content
    /// span — 60.52 s over piece A's 3026 fields — so the demuxer's own placement is
    /// already seam-exact, and the whole-keep estimate even under-states a ragged
    /// tail). Asserted via the same pure builders the engine writes the list with
    /// (`crossClipDurations` → `concatListContents`), on *real planned items* — the
    /// export deletes its work dir before returning, so the written file itself can't
    /// be inspected post-hoc.
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

    /// Two snapped trims of the same clip exported connected — a real concat of two
    /// field-coded `.ts` pieces. The joined TS output is the shell-validated shape:
    /// exact combined packet count (3026 + 6020 = 9046 on this capture), a **single
    /// one-field step (0.020 s) at the seam** — every consecutive presentation
    /// interval stays one field, no display gaps, no duplicates — strictly monotonic
    /// DTS, and an `-xerror`-clean decode.
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

        // Presentation cadence: uniform one-field (0.02 s) intervals through the seam —
        // an interval ≥ 1.5× the field would be a display gap, ≤ 0.5× a duplicate.
        // (The slice's only source cadence anomalies sit at its tail cut edge, outside
        // both kept spans — verified when the fixture recipe was validated.)
        let pts = packets.compactMap(\.pts).sorted()
        #expect(pts.count == packets.count, "every joined packet must carry a pts")
        let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }
        let field = deltas.sorted()[deltas.count / 2]
        #expect(!deltas.contains { $0 >= field * 1.5 }, "a display gap opened at the seam")
        #expect(!deltas.contains { $0 <= field * 0.5 }, "duplicate presentation timestamps")

        // Decode order: strictly monotonic DTS across the seam (the TS pieces carry
        // real DTS — the property the MKV piece would have destroyed).
        let dts = packets.compactMap(\.dts)
        #expect(dts.count == packets.count)
        #expect(!zip(dts, dts.dropFirst()).contains { $1 <= $0 }, "DTS not strictly monotonic")
    }

    /// A **mixed** connect join (issue #96): a snapped field-coded trim followed by a
    /// progressive clip — the synthesized x264 companion, planned through the same
    /// `ExportPlanner.planItem` path — exported to MKV through the real
    /// `ExportEngine.export`. The join policy cuts *both* clips' pieces as `.ts`
    /// (`pieceExtensions`; a mixed-container list is misplaced outright by the concat
    /// demuxer — shell-measured ~90× timeline displacement / duplicate-PTS collapse)
    /// and the concat list carries per-entry durations (none here: the field-coded
    /// entry emits none by policy, the last entry never does). The output must be
    /// genuine matroska, `-xerror`-decode clean, duplicate-PTS-free, and carry exactly
    /// the field span plus every companion frame.
    ///
    /// Clip order is field-coded **first** — the shell-validated direction. The
    /// reverse (progressive before field-coded) fails the `-xerror` gate in *every*
    /// piece/container shape: this capture carries no IDR slice at all, so a copy-cut
    /// piece can only enter on a recovery-point keyframe, and following foreign
    /// (progressive) content the recovered frames decode flagged corrupt — a
    /// content-level seam wall (the issue-#46 family), out of reach of containers or
    /// duration directives.
    @Test(.enabled(if: CopyCutFixture.available, skipMessage))
    func mixedJoinFieldCodedThenProgressiveExportsCleanMkv() async throws {
        let ctx = try await Self.context.value
        let companion = try await CopyCutFixture.ensureProgressiveCompanion()

        // Import the companion through the same pipeline the slice went through.
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

        // The join-level decisions the export below runs on: every piece `.ts`, and
        // per-entry duration directives (field-coded entry none, last entry none).
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

    /// A field-coded clip exported whole (no trims) stays on the plain remux path:
    /// the output carries exactly the source's video packet count — nothing split,
    /// nothing discarded by a needless segment-muxer pass.
    @Test(.enabled(if: CopyCutFixture.available, skipMessage))
    func wholeClipNoTrimExportStaysOnThePlainRemuxPath() async throws {
        let ctx = try await Self.context.value
        let out = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: out) }

        let clip = ctx.clip   // no in/out
        let settings = Self.settings(.ts, type: .videoOnly)
        let item = try Self.plannedItem(clip: clip, ctx: ctx, settings: settings)

        // The plan is the whole-clip single copy — the nil-cut shape that keeps the
        // plain remux path (`pieceExtension` returns the container even for MKV).
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
