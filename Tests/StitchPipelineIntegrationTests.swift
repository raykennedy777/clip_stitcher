import Testing
import Foundation
@testable import ClipStitcher

@Suite("Stitch pipeline (integration)", .serialized)
struct StitchPipelineIntegrationTests {
    private static func makeSources(in dir: URL) async throws -> (target: URL, fill: URL)? {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return nil }
        let target = dir.appendingPathComponent("target.mkv")
        let fill = dir.appendingPathComponent("fill.mkv")
        let red = try await ProcessRunner.run(ffmpeg, [
            "-v", "error",
            "-f", "lavfi", "-i", "color=c=red:size=320x240:rate=25:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:v", "libx264", "-g", "12", "-bf", "2", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-y", target.path])
        guard red.status == 0 else { return nil }
        let blue = try await ProcessRunner.run(ffmpeg, [
            "-v", "error",
            "-f", "lavfi", "-i", "color=c=blue:size=320x240:rate=25:duration=1",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=1",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=1",
            "-map", "0:v", "-map", "1:a", "-map", "2:a",
            "-c:v", "mpeg2video", "-c:a", "mp2", "-y", fill.path])
        guard blue.status == 0 else { return nil }
        return (target, fill)
    }

    private static func makeHevcSource(in dir: URL) async throws -> URL? {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return nil }
        let url = dir.appendingPathComponent("hevc.mkv")
        let made = try await ProcessRunner.run(ffmpeg, [
            "-v", "error",
            "-f", "lavfi", "-i", "color=c=green:size=320x240:rate=25:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=660:duration=1",
            "-c:v", "libx265", "-x265-params", "log-level=error", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-y", url.path])
        return made.status == 0 ? url : nil
    }

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-stitchjob-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func firstPixel(ffmpeg: URL, file: URL, frame: Int, scratch: URL) async throws -> (r: UInt8, g: UInt8, b: UInt8)? {
        let raw = scratch.appendingPathComponent("frame\(frame).rgb")
        let result = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-i", file.path,
            "-vf", "select=eq(n\\,\(frame))", "-frames:v", "1",
            "-f", "rawvideo", "-pix_fmt", "rgb24", "-y", raw.path])
        guard result.status == 0, let data = try? Data(contentsOf: raw), data.count >= 3 else { return nil }
        return (data[0], data[1], data[2])
    }

    private func meanVolume(ffmpeg: URL, file: URL, start: Double, duration: Double) async throws -> Double? {
        let result = try await ProcessRunner.run(ffmpeg, [
            "-ss", String(start), "-t", String(duration), "-i", file.path,
            "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-"])
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        guard let line = stderr.split(separator: "\n").first(where: { $0.contains("mean_volume:") }),
              let value = line.split(separator: " ").compactMap({ Double($0) }).first else { return nil }
        return value
    }

    @Test func stitchesMixedCodecJobFrameAccuratelyWithSelectedAudio() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }
        let ffmpeg = try FFTools.ffmpegURL()

        let job = try StitchJob.parse(Data("""
        {
          "version": 1,
          "clips": [
            { "path": "\(sources.target.path)", "inFrame": 5, "outFrame": 44,
              "audioTracks": [0], "target": true },
            { "path": "\(sources.fill.path)", "audioTracks": [1] }
          ],
          "output": { "container": "mkv" }
        }
        """.utf8))
        let output = dir.appendingPathComponent("out.mkv")
        let outcome = try await StitchPipeline.run(job: job, output: output)
        #expect(outcome.warnings.isEmpty)

        guard let ffprobe = try? FFTools.ffprobeURL() else { return }
        let count = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0", "-count_frames",
            "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", output.path])
        #expect(count.status == 0)
        let frames = Int((String(data: count.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(frames == 65)

        let inTarget = try await firstPixel(ffmpeg: ffmpeg, file: output, frame: 10, scratch: dir)
        #expect((inTarget?.r ?? 0) > 200 && (inTarget?.g ?? 255) < 60 && (inTarget?.b ?? 255) < 60)
        let inFill = try await firstPixel(ffmpeg: ffmpeg, file: output, frame: 50, scratch: dir)
        #expect((inFill?.b ?? 0) > 200 && (inFill?.r ?? 255) < 60 && (inFill?.g ?? 255) < 60)

        let level = try await meanVolume(ffmpeg: ffmpeg, file: output, start: 1.7, duration: 0.8)
        let unwrapped = try #require(level)
        #expect(unwrapped > -50)

        let codec = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name", "-of", "csv=p=0", output.path])
        #expect((String(data: codec.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "h264")
    }

    @Test func planReportPredictsTheFrameCountTheExportWrites() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }

        let hevc = try await Self.makeHevcSource(in: dir)
        let hevcClip = hevc.map { ",\n            { \"path\": \"\($0.path)\" }" } ?? ""
        let job = try StitchJob.parse(Data("""
        {
          "version": 1,
          "clips": [
            { "path": "\(sources.target.path)", "inFrame": 5, "outFrame": 44,
              "audioTracks": [0], "target": true },
            { "path": "\(sources.fill.path)", "audioTracks": [1] }\(hevcClip)
          ],
          "output": { "container": "mkv" }
        }
        """.utf8))
        let report = PlanReport.make(prepared: try await StitchPipeline.prepare(job: job))

        #expect(report.version == PlanReport.contractVersion)
        #expect(report.target == 0)
        #expect(report.clips.map(\.treatment)
                == [.smartRender, .conform] + (hevc == nil ? [] : [.conform]))
        #expect(report.clips[0].segments?.contains { $0.kind == .copy } == true)
        #expect(report.clips[0].copySafeKeyframes?.afterIn != nil)
        #expect(report.clips[1].reason?.contains { $0.property == "Codec" } == true)
        #expect(report.audio.bitrate.out == ExportEngine.audioBitrate)

        let decoded = try JSONDecoder().decode(PlanReport.self, from: report.jsonData())
        #expect(decoded == report)

        let output = dir.appendingPathComponent("out.mkv")
        _ = try await StitchPipeline.run(job: job, output: output)
        guard let ffprobe = try? FFTools.ffprobeURL() else { return }
        let count = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0", "-count_frames",
            "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", output.path])
        let written = Int((String(data: count.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(written == report.clips.reduce(0) { $0 + $1.expectedFrames })
        let t = report.totals
        #expect(written == t.copiedFrames + t.reEncodedFrames + t.conformedFrames)
    }

    @Test func aCachedPlanEqualsAnUncachedPlan() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }
        let hevc = try await Self.makeHevcSource(in: dir)
        let hevcClip = hevc.map { ",\n            { \"path\": \"\($0.path)\" }" } ?? ""
        let job = try StitchJob.parse(Data("""
        {
          "version": 1,
          "clips": [
            { "path": "\(sources.target.path)", "inFrame": 5, "outFrame": 44,
              "audioTracks": [0], "target": true },
            { "path": "\(sources.fill.path)", "audioTracks": [1] }\(hevcClip)
          ],
          "output": { "container": "mkv" }
        }
        """.utf8))
        let cache = IndexCache(directory: dir.appendingPathComponent("index-cache"))

        let uncached = try await StitchPipeline.prepare(job: job)
        let coldLog = LineSink(), warmLog = LineSink()
        let cold = try await StitchPipeline.prepare(job: job, log: { coldLog.append($0) },
                                                    indexCache: cache)
        let warm = try await StitchPipeline.prepare(job: job, log: { warmLog.append($0) },
                                                    indexCache: cache)
        let sourceCount = hevc == nil ? 2 : 3
        #expect(coldLog.lines.filter { $0.hasPrefix("Index cache miss") }.count == sourceCount)
        #expect(warmLog.lines.filter { $0.hasPrefix("Index cache hit") }.count == sourceCount)
        #expect(!warmLog.lines.contains { $0.hasPrefix("Indexing") })

        let reference = try PlanReport.make(prepared: uncached).jsonData()
        #expect(try PlanReport.make(prepared: cold).jsonData() == reference)
        #expect(try PlanReport.make(prepared: warm).jsonData() == reference)
        for (path, fresh) in uncached.facts {
            let hit = try #require(warm.facts[path])
            #expect(hit.probe == fresh.probe)
            #expect(hit.index.pts.map(\.bitPattern) == fresh.index.pts.map(\.bitPattern))
            #expect(hit.index.dts.map(\.bitPattern) == fresh.index.dts.map(\.bitPattern))
            #expect(hit.index.keyframeFlags == fresh.index.keyframeFlags)
            #expect(hit.fieldCoded == fresh.fieldCoded)
            #expect(hit.damageZones == fresh.damageZones)
        }

        let ffmpeg = try FFTools.ffmpegURL()
        let rewritten = dir.appendingPathComponent("fill-rewritten.mkv")
        _ = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-i", sources.fill.path, "-map", "0", "-c", "copy",
            "-metadata", "title=rewritten", "-y", rewritten.path])
        try FileManager.default.removeItem(at: sources.fill)
        try FileManager.default.moveItem(at: rewritten, to: sources.fill)
        let afterLog = LineSink()
        _ = try await StitchPipeline.prepare(job: job, log: { afterLog.append($0) },
                                             indexCache: cache)
        #expect(afterLog.lines.contains("Index cache miss fill.mkv"))
        #expect(afterLog.lines.contains { $0.hasPrefix("Index cache hit target.mkv") })
    }

    private static func streamFingerprint(_ file: URL) async throws -> (md5: String, packets: String) {
        let ffmpeg = try FFTools.ffmpegURL(), ffprobe = try FFTools.ffprobeURL()
        let md5 = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-i", file.path, "-map", "0", "-c", "copy", "-f", "framemd5", "-"])
        let packets = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-show_entries", "packet=stream_index,pts_time,dts_time,size,flags",
            "-of", "csv=p=0", file.path])
        return (String(data: md5.stdout, encoding: .utf8) ?? "",
                String(data: packets.stdout, encoding: .utf8) ?? "")
    }

    private static func job(_ sources: (target: URL, fill: URL), extra: String = "") throws -> StitchJob {
        try StitchJob.parse(Data("""
        {
          "version": 1,
          "clips": [
            { "path": "\(sources.target.path)", "inFrame": 5, "outFrame": 44,
              "audioTracks": [0], "target": true },
            { "path": "\(sources.fill.path)", "audioTracks": [1] }\(extra)
          ],
          "output": { "container": "mkv" }
        }
        """.utf8))
    }

    @Test func aWarmRenderIsStreamIdenticalToAColdOne() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }
        let hevc = try await Self.makeHevcSource(in: dir)
        let job = try Self.job(sources, extra: hevc.map { ",\n    { \"path\": \"\($0.path)\" }" } ?? "")
        let cacheDir = dir.appendingPathComponent("pieces")

        let uncached = dir.appendingPathComponent("uncached.mkv")
        let cold = dir.appendingPathComponent("cold.mkv")
        let warm = dir.appendingPathComponent("warm.mkv")
        _ = try await StitchPipeline.run(job: job, output: uncached)
        let coldLog = LineSink(), warmLog = LineSink()
        _ = try await StitchPipeline.run(job: job, output: cold, log: { coldLog.append($0) },
                                         pieceCache: PieceCache(directory: cacheDir))
        _ = try await StitchPipeline.run(job: job, output: warm, log: { warmLog.append($0) },
                                         pieceCache: PieceCache(directory: cacheDir))

        let encodes = 2 + (hevc == nil ? 1 : 2)
        #expect(coldLog.lines.contains("Piece cache: 0 hits, \(encodes) misses"))
        #expect(warmLog.lines.contains("Piece cache: \(encodes) hits, 0 misses"))
        let warmEncodes = warmLog.lines.filter { $0.contains(" reEncode [") || $0.contains(" conform: ") }
        #expect(warmEncodes.count == encodes)
        #expect(warmEncodes.allSatisfy { $0.hasSuffix("piece cache hit") })
        #expect(warmLog.lines.filter { $0.contains(" verify: ") }.count == (hevc == nil ? 2 : 3))

        let reference = try await Self.streamFingerprint(uncached)
        #expect(!reference.md5.isEmpty && !reference.packets.isEmpty)
        let coldPrint = try await Self.streamFingerprint(cold)
        let warmPrint = try await Self.streamFingerprint(warm)
        #expect(coldPrint.md5 == reference.md5)
        #expect(coldPrint.packets == reference.packets)
        #expect(warmPrint.md5 == coldPrint.md5)
        #expect(warmPrint.packets == coldPrint.packets)
    }

    @Test func movingOneMarkReEncodesOnlyThePieceItTouches() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }
        let cacheDir = dir.appendingPathComponent("pieces")
        func third(_ inFrame: Int) -> String {
            ",\n    { \"path\": \"\(sources.target.path)\", \"inFrame\": \(inFrame), \"outFrame\": 30, \"audioTracks\": [0] }"
        }
        _ = try await StitchPipeline.run(job: try Self.job(sources, extra: third(3)),
                                         output: dir.appendingPathComponent("cold.mkv"),
                                         pieceCache: PieceCache(directory: cacheDir))
        let log = LineSink()
        let warm = dir.appendingPathComponent("warm.mkv")
        _ = try await StitchPipeline.run(job: try Self.job(sources, extra: third(7)),
                                         output: warm, log: { log.append($0) },
                                         pieceCache: PieceCache(directory: cacheDir))
        let lines = log.lines
        func line(_ prefix: String) -> String? { lines.first { $0.hasPrefix(prefix) } }
        #expect(line("clip 0 s0 reEncode [5,")?.hasSuffix("piece cache hit") == true)
        #expect(line("clip 0 s2 reEncode [")?.hasSuffix("piece cache hit") == true)
        #expect(line("clip 1 conform: ")?.hasSuffix("piece cache hit") == true)
        #expect(line("clip 2 s0 reEncode [7,12)")?.hasSuffix("piece cache hit") == false)
        #expect(line("clip 2 s2 reEncode [24,31)")?.hasSuffix("piece cache hit") == true)
        #expect(lines.contains("Piece cache: 4 hits, 1 misses"))

        let uncached = dir.appendingPathComponent("uncached.mkv")
        _ = try await StitchPipeline.run(job: try Self.job(sources, extra: third(7)), output: uncached)
        let a = try await Self.streamFingerprint(warm), b = try await Self.streamFingerprint(uncached)
        #expect(a.md5 == b.md5)
        #expect(a.packets == b.packets)
    }

    final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    @Test func everyStageLogsItsElapsedTime() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }
        let job = try StitchJob.parse(Data("""
        {
          "version": 1,
          "clips": [
            { "path": "\(sources.target.path)", "inFrame": 5, "outFrame": 44,
              "audioTracks": [0], "target": true },
            { "path": "\(sources.fill.path)", "audioTracks": [1] }
          ],
          "output": { "container": "mkv" }
        }
        """.utf8))
        let sink = LineSink()
        _ = try await StitchPipeline.run(job: job, output: dir.appendingPathComponent("out.mkv"),
                                         log: { sink.append($0) })
        let lines = sink.lines
        func has(_ prefix: String, _ needle: String = " s") -> Bool {
            lines.contains { $0.hasPrefix(prefix) && $0.contains(needle) }
        }
        #expect(has("Probed target.mkv: "))
        #expect(has("Indexed target.mkv: ", " packets, 50 video frames"))
        #expect(has("Damage scan target.mkv: ", " candidate"))
        #expect(has("Planned 2 clips: "))
        #expect(has("clip 0 s0 reEncode [5,", " fps"))
        #expect(has("clip 0 s1 copy ["))
        #expect(has("clip 0 verify: "))
        #expect(has("clip 1 conform: ", "25 frames"))
        #expect(has("clip 1 verify: "))
        #expect(has("Joined 2 pieces: "))
        #expect(has("Muxed audio: "))
        #expect(has("Verified audio: "))
        #expect(lines.last?.hasPrefix("Total: 00:00:") == true)
    }

    @Test func jobSourceMismatchesAreRefusedAsInvalidJob() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }

        let job = try StitchJob.parse(Data("""
        {
          "version": 1,
          "clips": [
            { "path": "\(sources.target.path)", "target": true },
            { "path": "\(sources.fill.path)", "audioTracks": [5] }
          ]
        }
        """.utf8))
        let output = dir.appendingPathComponent("out.mkv")
        await #expect(throws: StitchJobError.audioTrackOutOfRange(clip: 1, index: 5, available: 2)) {
            try await StitchPipeline.run(job: job, output: output)
        }
    }
}
