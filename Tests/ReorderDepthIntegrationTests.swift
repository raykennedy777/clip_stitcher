import Testing
import Foundation
@testable import ClipStitcher

@Suite("Reorder depth across a join (integration)", .serialized)
struct ReorderDepthIntegrationTests {
    private static func makeSources(in dir: URL) async throws -> (target: URL, fill: URL)? {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return nil }
        let target = dir.appendingPathComponent("target.mkv")
        let fill = dir.appendingPathComponent("fill.mkv")
        let deep = try await ProcessRunner.run(ffmpeg, [
            "-v", "error",
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=8",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=8",
            "-c:v", "libx264", "-g", "12", "-bf", "3", "-pix_fmt", "yuv420p",
            "-x264-params", "b-pyramid=normal:b-adapt=0:scenecut=0",
            "-c:a", "aac", "-y", target.path])
        guard deep.status == 0 else { return nil }
        let shallow = try await ProcessRunner.run(ffmpeg, [
            "-v", "error",
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=2",
            "-c:v", "mpeg2video", "-pix_fmt", "yuv420p", "-c:a", "mp2", "-y", fill.path])
        guard shallow.status == 0 else { return nil }
        return (target, fill)
    }

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-reorderdepth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func presentationTimes(_ file: URL) async throws -> [Double] {
        let ffprobe = try FFTools.ffprobeURL()
        let out = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "frame=pts_time", "-of", "csv=p=0", file.path])
        #expect(out.status == 0)
        return (String(data: out.stdout, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .compactMap { Double($0.split(separator: ",")[0]) }
    }

    private func expectDistinctAndIncreasing(_ pts: [Double], _ label: String) {
        let duplicates = pts.count - Set(pts).count
        #expect(duplicates == 0, "\(label): \(duplicates) duplicated timestamps of \(pts.count) frames")
        let backwards = zip(pts.dropFirst(), pts).filter { $0 <= $1 }.count
        #expect(backwards == 0, "\(label): \(backwards) frames emitted out of order")
    }

    @Test func aShallowJoinOfConformThenReencodeKeepsEveryTimestamp() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }

        let job = try StitchJob.parse(Data("""
        {
          "version": 1,
          "clips": [
            { "path": "\(sources.fill.path)", "inFrame": 0, "outFrame": 24, "audioTracks": [0] },
            { "path": "\(sources.target.path)", "inFrame": 26, "outFrame": 34,
              "audioTracks": [0], "target": true }
          ],
          "output": { "container": "mkv" }
        }
        """.utf8))
        let output = dir.appendingPathComponent("shallow.mkv")
        let outcome = try await StitchPipeline.run(job: job, output: output)
        #expect(outcome.warnings.isEmpty)

        let pts = try await presentationTimes(output)
        #expect(pts.count == 34)
        expectDistinctAndIncreasing(pts, "shallow join")
    }

    @Test func aDeepJoinOfReencodedEdgesAroundCopiedDepth2FramesKeepsEveryTimestamp() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }

        let job = try StitchJob.parse(Data("""
        {
          "version": 1,
          "clips": [
            { "path": "\(sources.target.path)", "inFrame": 20, "outFrame": 159,
              "audioTracks": [0], "target": true }
          ],
          "output": { "container": "mkv" }
        }
        """.utf8))
        let output = dir.appendingPathComponent("deep.mkv")
        _ = try await StitchPipeline.run(job: job, output: output)

        let pts = try await presentationTimes(output)
        #expect(pts.count == 140)
        expectDistinctAndIncreasing(pts, "deep join")

        let ffprobe = try FFTools.ffprobeURL()
        let depth = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=has_b_frames", "-of", "csv=p=0", output.path])
        #expect((String(data: depth.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("2"))
    }
}
