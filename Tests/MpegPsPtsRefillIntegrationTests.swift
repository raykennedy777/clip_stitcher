import Testing
import Foundation
@testable import ClipStitcher

@Suite("MPEG-PS copy pieces keep their timestamps (integration)", .serialized)
struct MpegPsPtsRefillIntegrationTests {
    private static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-mpegps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    private static func packetsWithoutPts(_ file: URL) async throws -> Int {
        let ffprobe = try FFTools.ffprobeURL()
        let out = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "packet=pts_time", "-of", "csv=p=0", file.path])
        return (String(data: out.stdout, encoding: .utf8) ?? "")
            .split(separator: "\n").filter { $0.hasPrefix("N/A") }.count
    }

    private static func decodeComplaints(_ file: URL) async throws -> [String] {
        let ffmpeg = try FFTools.ffmpegURL()
        let out = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-xerror", "-i", file.path, "-f", "null", "-"])
        return (String(data: out.stderr, encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
    }

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

        let fixed = dir.appendingPathComponent("fixed.mkv")
        let good = try await ProcessRunner.run(ffmpeg, ExportEngine.remuxArguments(
            source: src, output: fixed,
            bitstreamFilter: ["-bsf:v", ExportEngine.ptsRefillFilter],
            inputFlags: ExportEngine.ptsRefillInputFlags(codec: "mpeg2video", ext: "mkv")))
        #expect(good.status == 0)
        #expect(try await Self.decodeComplaints(fixed) == [])
        #expect(try await Self.packetsWithoutPts(fixed) == 0)
        let sourceFrames = try await FrameIndexer.frameCount(url: src)
        #expect(try await FrameIndexer.frameCount(url: fixed) == sourceFrames)
    }

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

        #expect(try await Self.decodeComplaints(piece) == [])
        #expect(try await Self.packetsWithoutPts(piece) == 0)
        #expect(try await FrameIndexer.frameCount(url: piece)
            == plan.reduce(0) { $0 + $1.range.count })
    }

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

        #expect(try await Self.decodeComplaints(piece) == [])
        #expect(try await Self.packetsWithoutPts(piece) == 0)
        #expect(try await FrameIndexer.frameCount(url: piece)
            == plan.reduce(0) { $0 + $1.range.count })
    }
}
