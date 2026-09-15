import Testing
import Foundation
@testable import ClipStitcher

/// End-to-end net for the bounded verify decode (issue #114, ADR-0030): the gate must keep
/// refusing every defect it refused when it decoded the whole piece, while decoding only the
/// windows around the seams.
///
/// `VerifyWindowTests` pins where a window goes. Only a real ffmpeg run can show the thing
/// that fails silently: a window that is placed right but *entered* wrong. A decode entered at
/// an open-GOP keyframe prints the same orphaned-reference flood as the defect the gate exists
/// to catch, and a decode entered a GOP late covers no seam at all and passes everything — so
/// the claim under test is not "the windows are correct" but "the bounded gate and the
/// whole-piece gate refuse the same pieces".
///
/// **Owns no copyrighted bytes (ADR-0023).** The sources are synthesised from `testsrc2` into a
/// fully-gitignored folder and cached, so the suite runs on a fresh clone with nothing supplied
/// and skips itself when ffmpeg is absent. They are the broadcast shape the de-risk used: a
/// keyframe a second, an IDR every ten — so a copy may start only at the sparse IDRs and every
/// keyframe between them carries leading pictures.
///
/// Isolate it with `-only-testing:ClipStitcherTests/BoundedVerifyIntegrationTests`.
@Suite("Bounded verify decode (integration)", .serialized)
struct BoundedVerifyIntegrationTests {

    struct Spec {
        var name: String
        var codec: String
        var ext: String                 // the source's own container
        var encoder: [String]
        var rate: Int
        /// `bframes=1` instead of the default: no B-pyramid, so a re-encode that keeps its own
        /// pyramid lands deeper than the copied body it joins (ADR-0026's collapse).
        var shallowEncoder: [String]?
    }

    static let specs = [
        Spec(name: "h264", codec: "h264", ext: "mkv",
             encoder: ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "30",
                       "-x264-params", "open-gop=1:keyint=50:min-keyint=50:bframes=3"],
             rate: 50,
             shallowEncoder: ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "30",
                              "-x264-params", "open-gop=1:keyint=50:min-keyint=50:bframes=1"]),
        Spec(name: "hevc", codec: "hevc", ext: "mkv",
             encoder: ["-c:v", "libx265", "-preset", "ultrafast", "-crf", "32",
                       "-x265-params", "open-gop=1:keyint=50:min-keyint=50:bframes=4"],
             rate: 50,
             shallowEncoder: ["-c:v", "libx265", "-preset", "ultrafast", "-crf", "32",
                              "-x265-params", "open-gop=1:keyint=50:min-keyint=50:bframes=1:b-pyramid=0"]),
        Spec(name: "mpeg2", codec: "mpeg2video", ext: "ts",
             encoder: ["-c:v", "mpeg2video", "-q:v", "6", "-g", "25", "-bf", "2",
                       "-force_key_frames", "expr:gte(t,n_forced*10)"],
             rate: 25, shallowEncoder: nil),
    ]

    /// 60 s: long enough for a copy body holding several IDRs, short enough to synthesise and
    /// cache in a couple of seconds.
    static let seconds = 60
    /// One IDR per chunk. x264/x265 emit an IDR only at the start of an encode, so periodic
    /// IDRs inside an open-GOP stream come from concatenating short encodes — which is also
    /// how a broadcast stream gets them.
    static let chunkSeconds = 10

    static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/bounded-verify")
    }

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-bounded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func run(_ tool: URL, _ args: [String]) async throws -> ProcessResult {
        try await ProcessRunner.run(tool, args)
    }

    /// The cached source for one spec, synthesised on first use as `chunkSeconds` encodes
    /// concatenated, so each chunk boundary is an IDR and every other keyframe is open-GOP.
    static func source(_ spec: Spec, shallow: Bool = false) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let url = fixtureDirectory
            .appendingPathComponent("src_\(spec.name)\(shallow ? "_shallow" : "").\(spec.ext)")
        if fm.fileExists(atPath: url.path) { return url }
        let ffmpeg = try FFTools.ffmpegURL()
        let encoder = shallow ? (spec.shallowEncoder ?? spec.encoder) : spec.encoder
        let work = try scratch()
        defer { try? fm.removeItem(at: work) }
        var list = ""
        for i in 0..<(seconds / chunkSeconds) {
            let chunk = work.appendingPathComponent("c\(i).\(spec.ext)")
            let made = try await run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi",
                "-i", "testsrc2=size=320x180:rate=\(spec.rate):duration=\(chunkSeconds)"]
                + encoder + ["-pix_fmt", "yuv420p", chunk.path])
            guard made.status == 0 else {
                throw ExportError.cutFailed(String(data: made.stderr, encoding: .utf8) ?? "")
            }
            list += "file '\(chunk.path)'\n"
        }
        let listFile = work.appendingPathComponent("list.txt")
        try list.write(to: listFile, atomically: true, encoding: .utf8)
        let joined = try await run(ffmpeg, ExportEngine.concatArguments(
            listFile: listFile, output: url))
        guard joined.status == 0, fm.fileExists(atPath: url.path) else {
            throw ExportError.cutFailed(String(data: joined.stderr, encoding: .utf8) ?? "")
        }
        return url
    }

    /// What every case needs about a source: its index, its leading-picture counts, and the
    /// re-encode args the planner would pick for it.
    static func facts(_ spec: Spec, shallow: Bool = false) async throws
        -> (src: URL, index: FrameIndex, counts: [Int?], encoder: [String], start: Double) {
        let src = try await source(spec, shallow: shallow)
        let index = try await FrameIndexer.buildIndex(url: src)
        let probe = try await MediaProbe.probe(url: src)
        let counts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: index.keyframeFlags, dts: index.dts)
        let encoder = BoundaryReencodeEngine.reencodeVideoArgs(
            codec: spec.codec, profile: probe.video?.profile,
            pixelFormat: probe.video?.pixelFormat, fieldOrder: probe.video?.fieldOrder,
            bitrate: probe.video?.bitrate)
        let start = await MediaProbe.containerStartTime(url: src)
        return (src, index, counts, encoder, start)
    }

    static func location(_ plan: [PlannedSegment], _ piece: URL) -> VerificationLocation {
        VerificationLocation(clipIndex: 0, piece: piece.lastPathComponent, plan: plan)
    }

    // MARK: a clean piece passes, and the bound really is a bound

    /// The engine's own piece, produced and verified through `produceVideoPiece` — which runs
    /// the bounded gate. It throws on a refusal, so reaching the end is the assertion; the rest
    /// measures that the windows left most of the piece undecoded.
    @Test(arguments: [("h264", "mkv"), ("h264", "ts"),
                      ("hevc", "mkv"), ("hevc", "ts"),
                      ("mpeg2", "mkv"), ("mpeg2", "ts")])
    func aCleanPiecePassesTheBoundedGate(codec: String, ext: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let spec = Self.specs.first { $0.name == codec }!
        let f = try await Self.facts(spec)
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: f.counts, frameCount: f.index.count,
            inFrame: Int(Double(f.index.count) * 0.14),
            outFrame: Int(Double(f.index.count) * 0.56))
        #expect(plan.contains { $0.kind == .copy } && plan.contains { $0.kind == .reEncode },
                "the fixture must plan a copy between two re-encodes")
        let work = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: work) }
        let piece = try await BoundaryReencodeEngine.produceVideoPiece(
            ffmpeg, source: f.src, plan: plan, index: f.index, encoder: f.encoder,
            work: work, ext: ext, clipIndex: 0, codec: spec.codec,
            containerStart: f.start, reorderDepth: 1)

        // The windows the gate placed on the piece it just passed.
        let pieceIndex = try await FrameIndexer.buildIndex(url: piece)
        let windows = try #require(Self.windows(of: plan, piece: pieceIndex),
                                   "the piece must be long enough to bound")
        let span = (pieceIndex.pts.last ?? 0) - (pieceIndex.pts.first ?? 0)
        let bounded = windows.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        #expect(bounded < span / 2, "windows covered \(bounded) s of \(span) s")
    }

    static func windows(of plan: [PlannedSegment], piece: FrameIndex) -> [ClosedRange<Double>]? {
        let safe = CopySafeBoundaryDetector.copySafeFlags(
            keyframeFlags: piece.keyframeFlags, dts: piece.dts)
        var pts: [Int: Double] = [:]
        var flags: [Int: Bool] = [:]
        for i in piece.keyframeFlags.indices where piece.keyframeFlags[i] {
            pts[i] = piece.pts[i]
            flags[i] = safe[i]
        }
        return BoundaryReencodeEngine.verifyWindows(
            plan: plan, outputCounts: plan.map { $0.range.count },
            pieceKeyframePts: pts, pieceCopySafeFlags: flags,
            pieceSpan: (piece.pts.first ?? 0)...(piece.pts.last ?? 0))
    }

    // MARK: the three defects

    /// **(a) Orphaned leading pictures.** The copy body starts *at* an open-GOP keyframe, so
    /// its leading pictures reference a GOP that the re-encoded head replaced. Built in `.ts`:
    /// in Matroska the orphaned packets arrive with no timestamp and the mux itself fails, so
    /// the defect never reaches any gate (ADR-0030).
    @Test(arguments: ["h264", "hevc", "mpeg2"])
    func theGateRefusesAnOrphanedLeadingPictureSeam(codec: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let spec = Self.specs.first { $0.name == codec }!
        let f = try await Self.facts(spec)
        let inFrame = Int(Double(f.index.count) * 0.14)
        // The next keyframe that is NOT copy-safe — the whole point of the defect.
        guard let copyStart = (inFrame..<f.index.count).first(where: {
            f.index.keyframeFlags[$0] && (f.counts[$0] ?? 0) > 0
        }) else { return }
        let outFrame = Int(Double(f.index.count) * 0.56)
        guard let outCut = (copyStart..<f.index.count).last(where: {
            guard let n = f.counts[$0] else { return false }
            return $0 - n <= outFrame
        }), let n = f.counts[outCut], outCut - n > copyStart else { return }
        let plan = [PlannedSegment(kind: .reEncode, range: inFrame..<copyStart),
                    PlannedSegment(kind: .copy, range: copyStart..<(outCut - n),
                                   outCutKeyframe: outCut),
                    PlannedSegment(kind: .reEncode, range: (outCut - n)..<outFrame)]
        try await Self.expectSameVerdictAsTheWholePieceDecode(
            ffmpeg, spec, f, plan: plan, ext: "ts", mustRefuse: true)
    }

    /// **(b) Parameter-set mismatch** (the defect commit 8bacae6 fixed). The join's single
    /// container header comes from the **copied** first piece, and the re-encoded tail is built
    /// without `dump_extra`, so its frames decode against the source's parameter sets. MPEG-2
    /// cannot have it — its sequence header repeats per GOP in the elementary stream.
    @Test(arguments: ["h264", "hevc"])
    func theGateRefusesAParameterSetMismatch(codec: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let spec = Self.specs.first { $0.name == codec }!
        let f = try await Self.facts(spec)
        let plan = try #require(Self.copyFirstPlan(f.index, f.counts))
        // Only HEVC's decoder refuses it on a *synthetic* source: the tail re-encode's
        // parameter sets differ from the copied body's only in rate control, which an H.264
        // slice header survives. On the real Main 10 capture of issue #113 it was 165 error
        // lines. The parity assertion is the load-bearing one either way.
        try await Self.expectSameVerdictAsTheWholePieceDecode(
            ffmpeg, spec, f, plan: plan, ext: "mkv", mustRefuse: codec == "hevc",
            dropParameterSetRepeat: true)
    }

    /// **(c) Duplicate PTS at the seam** (ADR-0011 / ADR-0026). A shallow-reorder copy body
    /// sets the Matroska join's reorder depth, and the re-encoded tail keeps its encoder's
    /// B-pyramid — one frame deeper than the join can record. MPEG-2 has no pyramid to keep.
    @Test(arguments: ["h264", "hevc"])
    func boundingTheDecodeDoesNotMoveTheVerdictOnAPyramidSeam(codec: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let spec = Self.specs.first { $0.name == codec }!
        let f = try await Self.facts(spec, shallow: true)
        let plan = try #require(Self.copyFirstPlan(f.index, f.counts))
        // The collapse itself is a *timestamp* defect, and `ExportEngine.timestampDefect`
        // — which this change leaves whole-piece — is the gate that names it. What must hold
        // here is that bounding the decode did not move the verdict (ADR-0026 measured the
        // collapse on real 1080p50 HEVC; a synthetic join may or may not reproduce it).
        try await Self.expectSameVerdictAsTheWholePieceDecode(
            ffmpeg, spec, f, plan: plan, ext: "mkv", mustRefuse: false, keepBPyramid: true)
    }

    /// A copy-first plan: copy from the clip start to the deepest legal copy end, then one
    /// re-encoded tail. Defects (b) and (c) both need the **copy** to own the join's container
    /// header — behind a re-encoded first piece the header is that re-encode's own and a second
    /// re-encode with the same settings decodes against it unharmed.
    static func copyFirstPlan(_ index: FrameIndex, _ counts: [Int?]) -> [PlannedSegment]? {
        let outFrame = Int(Double(index.count) * 0.56)
        guard let outCut = (1..<index.count).last(where: {
            guard let n = counts[$0] else { return false }
            return $0 - n <= outFrame
        }), let n = counts[outCut], outCut - n > 0, outFrame > outCut - n else { return nil }
        return [PlannedSegment(kind: .copy, range: 0..<(outCut - n), outCutKeyframe: outCut),
                PlannedSegment(kind: .reEncode, range: (outCut - n)..<outFrame)]
    }

    /// Builds the piece the plan describes — with one thing deliberately wrong — and requires
    /// the **bounded** gate to reach the same verdict the whole-piece decode reaches. That
    /// parity is the claim of issue #114: shortening the decode must not cost the gate a
    /// refusal. `mustRefuse` additionally pins the cells ADR-0030 measured as defective, so a
    /// fixture that quietly stopped expressing its defect cannot make the test vacuous.
    ///
    /// The pieces are assembled from the engine's own argument builders, so what is under test
    /// is the gate, not a hand-rolled recipe.
    static func expectSameVerdictAsTheWholePieceDecode(
        _ ffmpeg: URL, _ spec: Spec,
        _ f: (src: URL, index: FrameIndex, counts: [Int?], encoder: [String], start: Double),
        plan: [PlannedSegment], ext: String, mustRefuse: Bool,
        dropParameterSetRepeat: Bool = false, keepBPyramid: Bool = false
    ) async throws {
        let work = try scratch()
        defer { try? FileManager.default.removeItem(at: work) }
        let encoder = keepBPyramid
            ? f.encoder
            : EncoderSelection.withEncoderParams(
                EncoderSelection.reorderDepthParams(depth: 1, forCodec: spec.codec),
                in: f.encoder, forCodec: spec.codec)
        var pieces: [URL] = []
        for (i, segment) in plan.enumerated() {
            let piece: URL
            if segment.kind == .reEncode {
                piece = work.appendingPathComponent("s\(i)_re.\(ext)")
                var args = BoundaryReencodeEngine.reencodeSegmentArguments(
                    source: f.src, range: segment.range, index: f.index,
                    encoder: encoder, output: piece)
                if dropParameterSetRepeat, let at = args.firstIndex(of: "-bsf:v") {
                    args.removeSubrange(at...(at + 1))
                }
                let made = try await run(ffmpeg, args)
                guard made.status == 0 else {
                    throw ExportError.cutFailed(String(data: made.stderr, encoding: .utf8) ?? "")
                }
            } else {
                let copyPlan = BoundaryReencodeEngine.copySegmentPlan(
                    copyRange: segment.range, outCutKeyframe: segment.outCutKeyframe,
                    index: f.index)
                let pattern = work.appendingPathComponent("s\(i)_cp_%03d.\(ext)").path
                let made = try await run(ffmpeg, ExportEngine.cutArguments(
                    source: f.src, plan: copyPlan, segmentPattern: pattern,
                    bitstreamFilter: ExportEngine.copyPieceBitstreamFilter(
                        codec: spec.codec, ext: ext)))
                guard made.status == 0 else {
                    throw ExportError.cutFailed(String(data: made.stderr, encoding: .utf8) ?? "")
                }
                piece = work.appendingPathComponent(String(
                    format: "s\(i)_cp_%03d.\(ext)", ExportEngine.wantedSegmentIndex(plan: copyPlan)))
            }
            guard FileManager.default.fileExists(atPath: piece.path) else {
                // A defect the muxer refuses first never reaches the gate — that is a refusal
                // too, and ADR-0030 records which cells behave this way.
                return
            }
            pieces.append(piece)
        }
        let listFile = work.appendingPathComponent("concat.txt")
        try ExportEngine.concatListContents(
            pieces: pieces, durations: BoundaryReencodeEngine.segmentSpans(plan, index: f.index))
            .write(to: listFile, atomically: true, encoding: .utf8)
        let joined = work.appendingPathComponent("joined.\(ext)")
        let concat = try await run(ffmpeg, ExportEngine.concatArguments(
            listFile: listFile, output: joined))
        guard concat.status == 0, FileManager.default.fileExists(atPath: joined.path) else {
            return   // the mux refused the defect before the gate could
        }
        // The two decodes, side by side on the same piece: the gate this change replaces, and
        // the gate it installs. Comparing them directly — rather than comparing two runs of the
        // *whole* verify — is what puts the bounded decode on trial even when another check
        // (a frame count, a timestamp) would have refused the piece first.
        let pieceIndex = try await FrameIndexer.buildIndex(url: joined)
        let windows = Self.windows(of: plan, piece: pieceIndex)
        let safe = CopySafeBoundaryDetector.copySafeFlags(
            keyframeFlags: pieceIndex.keyframeFlags, dts: pieceIndex.dts)
        let entries = pieceIndex.pts.indices
            .filter { pieceIndex.keyframeFlags[$0] && safe[$0] }
            .map { pieceIndex.pts[$0] }
        let wholeRefuses = await decodeRefuses(
            ffmpeg, joined, plan: plan, windows: nil, index: pieceIndex, entries: entries)
        let boundedRefuses = await decodeRefuses(
            ffmpeg, joined, plan: plan, windows: windows, index: pieceIndex, entries: entries)
        #expect(boundedRefuses == wholeRefuses,
                "bounding the decode moved its verdict: whole \(wholeRefuses), bounded \(boundedRefuses)")
        if mustRefuse {
            #expect(wholeRefuses,
                    "the fixture stopped expressing its defect — the whole-piece decode is clean")
        }

        // And the gate as a whole — every check, as `produceVideoPiece` runs it — still refuses
        // whatever the decode refuses.
        if wholeRefuses {
            await #expect(throws: ExportError.self) {
                try await BoundaryReencodeEngine.verifyPiece(
                    ffmpeg, joined, expectedCounts: plan.map { $0.range.count },
                    plan: plan, sourcePts: f.index.pts, at: location(plan, joined))
            }
        }
    }

    /// Whether one decode — whole-piece (`windows: nil`) or bounded — refuses the piece.
    static func decodeRefuses(_ ffmpeg: URL, _ piece: URL, plan: [PlannedSegment],
                              windows: [ClosedRange<Double>]?, index: FrameIndex,
                              entries: [Double]) async -> Bool {
        do {
            try await BoundaryReencodeEngine.decodeCheck(
                ffmpeg, piece, failureLabel: "decode", requireSilentDecode: true,
                at: location(plan, piece), windows: windows,
                pieceStart: index.pts.first ?? 0, copySafeKeyframePts: entries)
            return false
        } catch {
            return true
        }
    }
}
