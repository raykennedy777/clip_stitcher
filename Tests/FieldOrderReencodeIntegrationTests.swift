import Testing
import Foundation
@testable import ClipStitcher

@Suite("Interlaced re-encode scan direction (integration)", .serialized)
struct FieldOrderReencodeIntegrationTests {
    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-fieldorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func interlacedSource(_ ffmpeg: URL, in work: URL) async throws -> URL {
        let url = work.appendingPathComponent("src.ts")
        let made = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-y", "-f", "lavfi",
            "-i", "testsrc2=size=352x288:rate=50:duration=2",
            "-vf", "tinterlace=mode=interleave_top,fps=25,setparams=field_mode=tff",
            "-c:v", "mpeg2video", "-pix_fmt", "yuv420p", "-flags", "+ildct+ilme",
            "-q:v", "4", "-g", "12", "-an", url.path,
        ])
        guard made.status == 0 else {
            throw ExportError.cutFailed(String(data: made.stderr, encoding: .utf8) ?? "")
        }
        return url
    }

    @Test(arguments: [("tt", "tt"), ("bb", "bb")])
    func aReencodedPieceCarriesTheAskedForScanDirection(asked: String, expected: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let work = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: work) }

        let src = try await Self.interlacedSource(ffmpeg, in: work)
        #expect(try await MediaProbe.probe(url: src).video?.fieldOrder == "tt")

        let index = try await FrameIndexer.buildIndex(url: src)
        let probe = try await MediaProbe.probe(url: src)
        let encoder = BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "mpeg2video", profile: probe.video?.profile,
            pixelFormat: probe.video?.pixelFormat, fieldOrder: asked,
            bitrate: probe.video?.bitrate)
        let piece = work.appendingPathComponent("piece_\(asked).ts")
        let args = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 0..<min(25, index.count), index: index,
            encoder: encoder, output: piece)

        #expect(args.filter { $0 == "-vf" }.count == 1)

        let made = try await ProcessRunner.run(ffmpeg, args)
        #expect(made.status == 0, "\(String(data: made.stderr, encoding: .utf8) ?? "")")
        #expect(try await MediaProbe.probe(url: piece).video?.fieldOrder == expected)
    }

    @Test func aRepairedPieceCarriesTheAskedForScanDirection() async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let work = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: work) }

        let src = try await Self.interlacedSource(ffmpeg, in: work)
        let index = try await FrameIndexer.buildIndex(url: src)
        let probe = try await MediaProbe.probe(url: src)
        let encoder = BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "mpeg2video", profile: probe.video?.profile,
            pixelFormat: probe.video?.pixelFormat, fieldOrder: "bb",
            bitrate: probe.video?.bitrate)
        let piece = work.appendingPathComponent("repaired.ts")
        let args = BoundaryReencodeEngine.repairedSegmentArguments(
            source: src, range: 0..<min(25, index.count), index: index, zones: [],
            containerStart: await MediaProbe.containerStartTime(url: src),
            frameRate: "25/1", encoder: encoder, output: piece)

        #expect(args.filter { $0 == "-vf" }.count == 1)

        let made = try await ProcessRunner.run(ffmpeg, args)
        #expect(made.status == 0, "\(String(data: made.stderr, encoding: .utf8) ?? "")")
        #expect(try await MediaProbe.probe(url: piece).video?.fieldOrder == "bb")
    }

    @Test(arguments: ["tt", "bb"])
    func anH264ReencodedPieceIsCodedInTheAskedForScanDirection(asked: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let work = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: work) }

        let src = try await Self.interlacedSource(ffmpeg, in: work)
        let index = try await FrameIndexer.buildIndex(url: src)
        let piece = work.appendingPathComponent("h264_\(asked).ts")
        let encoder = BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "h264", pixelFormat: "yuv420p", fieldOrder: asked)
        let args = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 0..<min(25, index.count), index: index,
            encoder: encoder, output: piece)
        #expect(args.filter { $0 == "-vf" }.count == 1)

        let made = try await ProcessRunner.run(ffmpeg, args)
        #expect(made.status == 0, "\(String(data: made.stderr, encoding: .utf8) ?? "")")
        #expect(await MediaProbe.codedFieldOrder(url: piece) == asked)
    }

    @Test(arguments: [("tt", "mkv", "25/1"), ("bb", "mkv", "25/1"), ("tt", "mp4", "25/1"), ("bb", "mp4", "25/1"),
                      ("tt", "mkv", "50/1"), ("bb", "mp4", "50/1")])
    func aConformedH264PieceIsCodedInTheAskedForScanDirection(asked: String, ext: String, rate: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let work = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: work) }

        let src = work.appendingPathComponent("prog.mp4")
        let made = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=352x288:rate=50:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "12", "-an", src.path,
        ])
        #expect(made.status == 0)
        guard let source = try await MediaProbe.probe(url: src).video else { return }
        var target = source
        target.fieldOrder = asked; target.frameRate = rate
        target.profile = "High"; target.level = "30"

        let piece = work.appendingPathComponent("conf_\(asked).\(ext)")
        let args = ["-v", "error", "-xerror", "-y", "-i", src.path]
            + ConformEngine.conformVideoArgs(source: source, target: target) + ["-an", piece.path]
        let run = try await ProcessRunner.run(ffmpeg, args)
        #expect(run.status == 0, "\(String(data: run.stderr, encoding: .utf8) ?? "")")

        let coded = await MediaProbe.codedFieldOrder(url: piece)
        #expect(coded == asked)
        #expect(try await FrameIndexer.frameCount(url: piece) == (rate == "25/1" ? 25 : 50))
        var probed = try await MediaProbe.probe(url: piece).video
        probed?.fieldOrder = coded
        #expect(probed.map { MatchEvaluator.conformedVideoMatches($0, target) } == true)
        var otherSpelling = target
        otherSpelling.fieldOrder = asked == "tt" ? "tb" : "bt"
        #expect(probed.map { MatchEvaluator.conformedVideoMatches($0, otherSpelling) } == true)
        var wrongWay = target
        wrongWay.fieldOrder = asked == "tt" ? "bb" : "tt"
        #expect(probed.map { MatchEvaluator.conformedVideoMatches($0, wrongWay) } == false)
    }

    @Test(arguments: ["tt", "bb"])
    func theMbaffTailCarriesTheAskedForScanDirection(asked: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL(), let ffprobe = try? FFTools.ffprobeURL() else { return }
        let work = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: work) }

        let src = try await Self.interlacedSource(ffmpeg, in: work)
        let index = try await FrameIndexer.buildIndex(url: src)
        let piece = work.appendingPathComponent("tail_\(asked).ts")
        let args = BoundaryReencodeEngine.reencodeSegmentArguments(
            source: src, range: 0..<min(25, index.count), index: index,
            encoder: BoundaryReencodeEngine.mbaffRepairVideoArgs(fieldOrder: asked),
            output: piece)
        #expect(args.filter { $0 == "-vf" }.count == 1)

        let made = try await ProcessRunner.run(ffmpeg, args)
        #expect(made.status == 0, "\(String(data: made.stderr, encoding: .utf8) ?? "")")

        let flags = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0", "-show_frames",
            "-show_entries", "frame=interlaced_frame,top_field_first",
            "-of", "csv=p=0", "-read_intervals", "%+#3", piece.path,
        ])
        let rows = (String(data: flags.stdout, encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
        #expect(!rows.isEmpty)
        for row in rows {
            let f = row.split(separator: ",").map(String.init)
            #expect(f.first == "1")
            #expect(f.dropFirst().first == (asked == "tt" ? "1" : "0"))
        }
    }
}
