import Testing
import Foundation
@testable import ClipStitcher

/// The regression net for issue #116: an MPEG-**PS** source's stream-copied piece, muxed to
/// `.mkv`, must decode silently.
///
/// An MPEG-PS PES packet carries one timestamp. When the muxer packs two access units into one
/// PES, the second loses its PTS — and that second one is an **anchor** (I or P) picture, whose
/// PTS leads its DTS by the reorder delay. The old refill (`ExportEngine.ptsRefillFilter`, a
/// `setts` that fills a missing PTS from the packet's own DTS) therefore placed it `bf` frames
/// early, on the previous anchor's PTS. Matroska wrote the duplicate, the verify decode emitted
/// two frames on one timestamp, and `-f null -` printed "Application provided invalid, non
/// monotonically increasing dts to muxer". The pictures were correct, so `requireSilentDecode`
/// (ADR-0030) refused a good piece — the false-fail class of issue #19.
///
/// `ExportEngine.ptsRefillInputFlags` adds `-fflags +genpts` to the same runs, so the demuxer
/// derives the true reordered PTS before the fallback ever sees the packet.
///
/// Owns no copyrighted bytes (ADR-0023): the source is synthesised with `lavfi` into a temp
/// dir. Run it alone with
/// `-only-testing:ClipStitcherTests/MpegPsPtsRefillIntegrationTests`.
@Suite("MPEG-PS copy pieces keep their timestamps (integration)", .serialized)
struct MpegPsPtsRefillIntegrationTests {

    private static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-mpegps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 60 s of MPEG-2 in an MPEG-PS container, built as six 10 s encodes concatenated so each
    /// chunk boundary is a leading-picture-free entry the planner can copy from. The PS muxer
    /// is what drops the timestamps, so they appear on the concatenated file however the
    /// chunks were written.
    private static func makeSource(in dir: URL) async throws -> URL? {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return nil }
        var list = ""
        for i in 0..<6 {
            let chunk = dir.appendingPathComponent("c\(i).mpg")
            let made = try await ProcessRunner.run(ffmpeg, [
                "-v", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=10",
                "-c:v", "mpeg2video", "-q:v", "6", "-g", "25", "-bf", "2",
                "-pix_fmt", "yuv420p", chunk.path])
            guard made.status == 0 else { return nil }
            list += "file '\(chunk.path)'\n"
        }
        let listFile = dir.appendingPathComponent("list.txt")
        try list.write(to: listFile, atomically: true, encoding: .utf8)
        let src = dir.appendingPathComponent("src.mpg")
        let joined = try await ProcessRunner.run(ffmpeg, ExportEngine.concatArguments(
            listFile: listFile, output: src))
        guard joined.status == 0 else { return nil }
        return src
    }

    /// How many video packets of a file carry no PTS at all. This is what makes the fixture
    /// express the defect; a source that has none would pass whatever the app did.
    private static func packetsWithoutPts(_ file: URL) async throws -> Int {
        let ffprobe = try FFTools.ffprobeURL()
        let out = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "packet=pts_time", "-of", "csv=p=0", file.path])
        return (String(data: out.stdout, encoding: .utf8) ?? "")
            .split(separator: "\n").filter { $0.hasPrefix("N/A") }.count
    }

    /// Everything ffmpeg said on a plain whole-piece decode. Empty means silent — the bar
    /// `requireSilentDecode` holds a piece to. The exit status is blind to these lines.
    private static func decodeComplaints(_ file: URL) async throws -> [String] {
        let ffmpeg = try FFTools.ffmpegURL()
        let out = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-xerror", "-i", file.path, "-f", "null", "-"])
        return (String(data: out.stderr, encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// The red half, so the fixture is on trial as much as the fix: with the `setts` fallback
    /// alone — the whole refill before issue #116 — the copied piece is **noisy**. If this
    /// stops failing, the source stopped carrying missing-PTS packets and the green half below
    /// proves nothing.
    @Test func theOldDtsOnlyRefillStillMakesTheCopiedPieceNoisy() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let ffmpeg = try? FFTools.ffmpegURL(),
              let src = try await Self.makeSource(in: dir) else { return }
        #expect(try await Self.packetsWithoutPts(src) > 0,
                "the fixture must carry packets with no PTS, or it tests nothing")

        let old = dir.appendingPathComponent("old.mkv")
        let made = try await ProcessRunner.run(ffmpeg, ExportEngine.remuxArguments(
            source: src, output: old,
            bitstreamFilter: ["-bsf:v", ExportEngine.ptsRefillFilter]))
        #expect(made.status == 0)
        #expect(!(try await Self.decodeComplaints(old)).isEmpty,
                "the DTS-only refill should still place an anchor picture early")

        // And the same run with the demuxer refill added is silent, with every PTS present.
        let fixed = dir.appendingPathComponent("fixed.mkv")
        let good = try await ProcessRunner.run(ffmpeg, ExportEngine.remuxArguments(
            source: src, output: fixed,
            bitstreamFilter: ["-bsf:v", ExportEngine.ptsRefillFilter],
            inputFlags: ExportEngine.ptsRefillInputFlags(codec: "mpeg2video", ext: "mkv")))
        #expect(good.status == 0)
        #expect(try await Self.decodeComplaints(fixed) == [])
        #expect(try await Self.packetsWithoutPts(fixed) == 0)
        // Frame for frame the same copy: only the timestamps moved.
        let sourceFrames = try await FrameIndexer.frameCount(url: src)
        #expect(try await FrameIndexer.frameCount(url: fixed) == sourceFrames)
    }

    /// The measurement the issue reports: `produceVideoPiece` on the `.mpg` source into `.mkv`,
    /// on a plan of `reEncode · copy · reEncode`. It verifies the piece itself and throws on a
    /// refusal, so reaching the end is the assertion.
    @Test func aReencodeCopyReencodePieceFromAnMpegPsSourceVerifiesIntoMkv() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let ffmpeg = try? FFTools.ffmpegURL(),
              let src = try await Self.makeSource(in: dir) else { return }
        #expect(try await Self.packetsWithoutPts(src) > 0)

        let index = try await FrameIndexer.buildIndex(url: src)
        let probe = try await MediaProbe.probe(url: src)
        let counts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: index.keyframeFlags, dts: index.dts)
        // A wide keep, so the copied body spans the missing-PTS packets rather than skipping
        // past them: they sit at roughly 38 % and 86 % of this source.
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts, frameCount: index.count,
            inFrame: Int(Double(index.count) * 0.12),
            outFrame: Int(Double(index.count) * 0.92))
        #expect(plan.contains { $0.kind == .copy } && plan.contains { $0.kind == .reEncode },
                "the fixture must plan a copy between re-encodes")

        let work = dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let piece = try await BoundaryReencodeEngine.produceVideoPiece(
            ffmpeg, source: src, plan: plan, index: index,
            encoder: BoundaryReencodeEngine.reencodeVideoArgs(
                codec: "mpeg2video", profile: probe.video?.profile,
                pixelFormat: probe.video?.pixelFormat, fieldOrder: probe.video?.fieldOrder,
                bitrate: probe.video?.bitrate),
            work: work, ext: "mkv", clipIndex: 0, codec: "mpeg2video",
            containerStart: await MediaProbe.containerStartTime(url: src), reorderDepth: 1)

        // The gate that refused it before, stated directly on the shipped piece.
        #expect(try await Self.decodeComplaints(piece) == [])
        #expect(try await Self.packetsWithoutPts(piece) == 0)
        #expect(try await FrameIndexer.frameCount(url: piece)
            == plan.reduce(0) { $0 + $1.range.count })
    }

    /// Issue #118: the same measurement, but through Clip Doctor's repair-only bounded-keyframe
    /// copy (`copyStrategy: .boundedKeyframe`), which used to skip this refill entirely and hit
    /// the Matroska "Can't write packet with unknown timestamp" refusal on its own copy span.
    @Test func aBoundedKeyframeCopyPieceFromAnMpegPsSourceVerifiesIntoMkv() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let ffmpeg = try? FFTools.ffmpegURL(),
              let src = try await Self.makeSource(in: dir) else { return }
        #expect(try await Self.packetsWithoutPts(src) > 0)

        let index = try await FrameIndexer.buildIndex(url: src)
        let probe = try await MediaProbe.probe(url: src)
        let counts = CopySafeBoundaryDetector.leadingPictureCounts(
            keyframeFlags: index.keyframeFlags, dts: index.dts)
        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: counts, frameCount: index.count,
            inFrame: Int(Double(index.count) * 0.12),
            outFrame: Int(Double(index.count) * 0.92))
        #expect(plan.contains { $0.kind == .copy } && plan.contains { $0.kind == .reEncode },
                "the fixture must plan a copy between re-encodes")

        let work = dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let piece = try await BoundaryReencodeEngine.produceVideoPiece(
            ffmpeg, source: src, plan: plan, index: index,
            encoder: BoundaryReencodeEngine.reencodeVideoArgs(
                codec: "mpeg2video", profile: probe.video?.profile,
                pixelFormat: probe.video?.pixelFormat, fieldOrder: probe.video?.fieldOrder,
                bitrate: probe.video?.bitrate),
            work: work, ext: "mkv", clipIndex: 0, codec: "mpeg2video",
            containerStart: await MediaProbe.containerStartTime(url: src),
            copyStrategy: .boundedKeyframe, reorderDepth: 1)

        // The gate that refused it before, stated directly on the shipped piece.
        #expect(try await Self.decodeComplaints(piece) == [])
        #expect(try await Self.packetsWithoutPts(piece) == 0)
        #expect(try await FrameIndexer.frameCount(url: piece)
            == plan.reduce(0) { $0 + $1.range.count })
    }
}
