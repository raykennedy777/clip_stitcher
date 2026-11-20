import Testing
import Foundation
@testable import ClipStitcher

@Suite("Copy head seek (integration)", .serialized)
struct CopyHeadSeekIntegrationTests {
    struct Source {
        var name: String
        var codec: String
        var encoder: [String]
        var rate: Int
        var gop: Int
    }

    static let sources = [
        Source(name: "h264", codec: "h264",
               encoder: ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "30",
                         "-g", "50", "-keyint_min", "50", "-bf", "3"],
               rate: 50, gop: 50),
        Source(name: "hevc", codec: "hevc",
               encoder: ["-c:v", "libx265", "-preset", "ultrafast", "-crf", "32",
                         "-x265-params", "open-gop=1:keyint=50:min-keyint=50:bframes=4"],
               rate: 50, gop: 50),
        Source(name: "mpeg2", codec: "mpeg2video",
               encoder: ["-c:v", "mpeg2video", "-q:v", "6", "-g", "25", "-bf", "2"],
               rate: 25, gop: 25),
    ]

    static let seconds = 180

    static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/head-seek")
    }

    static func source(_ spec: Source) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let url = fixtureDirectory
            .appendingPathComponent("src_\(spec.name).\(spec.codec == "mpeg2video" ? "mpg" : "mkv")")
        if fm.fileExists(atPath: url.path) { return url }
        let ffmpeg = try FFTools.ffmpegURL()
        let args = ["-v", "error", "-y", "-f", "lavfi",
                    "-i", "testsrc2=size=640x360:rate=\(spec.rate):duration=\(seconds)"]
            + spec.encoder + ["-pix_fmt", "yuv420p", url.path]
        let result = try await ProcessRunner.run(ffmpeg, args)
        guard result.status == 0, fm.fileExists(atPath: url.path) else {
            throw ExportError.cutFailed(String(data: result.stderr, encoding: .utf8) ?? "synthesis failed")
        }
        return url
    }

    static func fingerprint(_ url: URL) async throws -> [String] {
        let ffprobe = try FFTools.ffprobeURL()
        let result = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "packet=pts_time,dts_time,size,flags", "-of", "csv=p=0", url.path,
        ])
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    static func totalBytes(in directory: URL) -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(0) { sum, name in
            let attrs = try? fm.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return sum + ((attrs?[.size] as? Int) ?? 0)
        }
    }

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-headseek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test(arguments: [("h264", "mkv"), ("h264", "mp4"), ("h264", "ts"),
                      ("hevc", "mkv"), ("hevc", "mp4"), ("hevc", "ts"),
                      ("mpeg2", "mkv"), ("mpeg2", "mp4"), ("mpeg2", "ts")])
    func aSeekedCopyShipsTheSamePieceForAFractionOfTheTemp(codec: String, ext: String) async throws {
        let spec = Self.sources.first { $0.name == codec }!
        let src = try await Self.source(spec)
        let ffmpeg = try FFTools.ffmpegURL()
        let index = try await FrameIndexer.buildIndex(url: src)
        let containerStart = await MediaProbe.containerStartTime(url: src)
        let start = try #require(index.pts.first)

        let keyframes = (0..<index.count).filter { index.keyframeFlags[$0] }
        let lo = try #require(keyframes.last { index.pts[$0] - start <= 150 })
        let outCut = try #require(keyframes.first { index.pts[$0] - start >= 155 })
        let copyPlan = BoundaryReencodeEngine.copySegmentPlan(
            copyRange: lo..<outCut, outCutKeyframe: outCut, index: index)
        #expect(copyPlan.inSegmentTime != nil, "the span must have a head to skip")
        let bsf = ExportEngine.copyPieceBitstreamFilter(codec: spec.codec, ext: ext)

        let refDir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: refDir) }
        let refRun = try await ProcessRunner.run(ffmpeg, ExportEngine.cutArguments(
            source: src, plan: copyPlan,
            segmentPattern: refDir.appendingPathComponent("ref_%03d.\(ext)").path,
            bitstreamFilter: bsf))
        #expect(refRun.status == 0,
                "reference cut: \(String(data: refRun.stderr, encoding: .utf8) ?? "")")
        let reference = refDir.appendingPathComponent(
            String(format: "ref_%03d.\(ext)", ExportEngine.wantedSegmentIndex(plan: copyPlan)))
        let referencePackets = try await Self.fingerprint(reference)
        let referenceBytes = Self.totalBytes(in: refDir)

        let plan = [PlannedSegment(kind: .copy, range: lo..<(lo + referencePackets.count),
                                   outCutKeyframe: outCut)]

        let work = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: work) }
        let piece = try await BoundaryReencodeEngine.produceVideoPiece(
            ffmpeg, source: src, plan: plan, index: index,
            encoder: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], work: work, ext: ext,
            clipIndex: 0, codec: spec.codec, containerStart: containerStart)

        let producedPackets = try await Self.fingerprint(piece)
        #expect(producedPackets == referencePackets)

        let seekedBytes = Self.totalBytes(in: work)
        let pieceBytes = (try? FileManager.default
            .attributesOfItem(atPath: piece.path)[.size] as? Int) ?? 0
        #expect(seekedBytes < referenceBytes / 4,
                "temp \(seekedBytes) vs unseeked \(referenceBytes)")
        #expect(seekedBytes < pieceBytes * 3,
                "the read should be the span plus pre-roll, not the file before it")

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        #expect(leftovers == [piece.lastPathComponent],
                "left behind: \(leftovers.sorted())")
    }

    @Test func aCopyWithNoRoomToSeekFallsBackToTheUnseekedRead() async throws {
        let src = try await Self.source(Self.sources[0])
        let ffmpeg = try FFTools.ffmpegURL()
        let index = try await FrameIndexer.buildIndex(url: src)
        let containerStart = await MediaProbe.containerStartTime(url: src)

        let atStart = SegmentPlan(inFrame: 0, outFrame: 100, inSegmentTime: 0.0, outSegmentTime: 2.0)
        #expect(ExportEngine.copyHeadSeekTarget(
            plan: atStart, index: index, containerStart: containerStart) == nil)
        let probeDir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: probeDir) }
        #expect(await BoundaryReencodeEngine.copyHeadSeek(
            ffmpeg, source: src, plan: atStart, index: index, containerStart: containerStart,
            probeOutput: probeDir.appendingPathComponent("probe.nut")) == nil)

        let keyframes = (0..<index.count).filter { index.keyframeFlags[$0] }
        let second = keyframes[1]
        let plan = BoundaryReencodeEngine.copySegmentPlan(
            copyRange: second..<keyframes[3], outCutKeyframe: keyframes[3], index: index)
        let seek = await BoundaryReencodeEngine.copyHeadSeek(
            ffmpeg, source: src, plan: plan, index: index, containerStart: containerStart,
            probeOutput: probeDir.appendingPathComponent("probe2.nut"))
        let measured = try #require(seek)
        #expect(measured.origin < plan.inSegmentTime!)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: probeDir.path)) == [])
    }
}
