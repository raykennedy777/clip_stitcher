import Testing
import Foundation
@testable import ClipStitcher

@Suite("Bounded verify decode (integration)", .serialized)
struct BoundedVerifyIntegrationTests {
    struct Spec {
        var name: String
        var codec: String
        var ext: String
        var encoder: [String]
        var rate: Int
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

    static let seconds = 60
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

    @Test(arguments: ["h264", "hevc", "mpeg2"])
    func theGateRefusesAnOrphanedLeadingPictureSeam(codec: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let spec = Self.specs.first { $0.name == codec }!
        let f = try await Self.facts(spec)
        let inFrame = Int(Double(f.index.count) * 0.14)
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

    @Test(arguments: ["h264", "hevc"])
    func theGateRefusesAParameterSetMismatch(codec: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let spec = Self.specs.first { $0.name == codec }!
        let f = try await Self.facts(spec)
        let plan = try #require(Self.copyFirstPlan(f.index, f.counts))
        try await Self.expectSameVerdictAsTheWholePieceDecode(
            ffmpeg, spec, f, plan: plan, ext: "mkv", mustRefuse: codec == "hevc",
            dropParameterSetRepeat: true)
    }

    @Test(arguments: ["h264", "hevc"])
    func boundingTheDecodeDoesNotMoveTheVerdictOnAPyramidSeam(codec: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let spec = Self.specs.first { $0.name == codec }!
        let f = try await Self.facts(spec, shallow: true)
        let plan = try #require(Self.copyFirstPlan(f.index, f.counts))
        try await Self.expectSameVerdictAsTheWholePieceDecode(
            ffmpeg, spec, f, plan: plan, ext: "mkv", mustRefuse: false, keepBPyramid: true)
    }

    static func copyFirstPlan(_ index: FrameIndex, _ counts: [Int?]) -> [PlannedSegment]? {
        let outFrame = Int(Double(index.count) * 0.56)
        guard let outCut = (1..<index.count).last(where: {
            guard let n = counts[$0] else { return false }
            return $0 - n <= outFrame
        }), let n = counts[outCut], outCut - n > 0, outFrame > outCut - n else { return nil }
        return [PlannedSegment(kind: .copy, range: 0..<(outCut - n), outCutKeyframe: outCut),
                PlannedSegment(kind: .reEncode, range: (outCut - n)..<outFrame)]
    }

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
            return
        }
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

        if wholeRefuses {
            await #expect(throws: ExportError.self) {
                try await BoundaryReencodeEngine.verifyPiece(
                    ffmpeg, joined, expectedCounts: plan.map { $0.range.count },
                    plan: plan, sourcePts: f.index.pts, at: location(plan, joined))
            }
        }
    }

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
