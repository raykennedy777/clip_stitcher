import Testing
import Foundation
@testable import ClipStitcher

@Suite("Back-to-back keyframe out-cut (integration)", .serialized)
struct BackToBackKeyframeCutIntegrationTests {
    struct Source {
        var name: String
        var codec: String
        var ext: String
        var encoder: [String]
    }

    static let forcedKeyframes = "expr:eq(n,0)+eq(n,50)+eq(n,100)+eq(n,101)+eq(n,150)"

    static let sources = [
        Source(name: "mpeg2", codec: "mpeg2video", ext: "ts",
               encoder: ["-c:v", "mpeg2video", "-q:v", "6", "-g", "1000", "-bf", "2",
                         "-flags", "+cgop", "-sc_threshold", "1000000000"]),
    ]

    static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/back-to-back-keyframes")
    }

    static func source(_ spec: Source) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let url = fixtureDirectory.appendingPathComponent("src_\(spec.name).\(spec.ext)")
        if fm.fileExists(atPath: url.path) { return url }
        let ffmpeg = try FFTools.ffmpegURL()
        let args = ["-v", "error", "-y", "-f", "lavfi",
                    "-i", "testsrc2=size=320x240:rate=25:duration=8"]
            + spec.encoder
            + ["-force_key_frames", forcedKeyframes, "-pix_fmt", "yuv420p", url.path]
        let result = try await ProcessRunner.run(ffmpeg, args)
        guard result.status == 0, fm.fileExists(atPath: url.path) else {
            throw ExportError.cutFailed(String(data: result.stderr, encoding: .utf8) ?? "synthesis failed")
        }
        return url
    }

    @Test(arguments: [("mpeg2", "mkv"), ("mpeg2", "mp4"), ("mpeg2", "ts")])
    func anOutPointOnTheKeyframeBeforeAKeyframeKeepsEveryFrame(codec: String, ext: String) async throws {
        let spec = Self.sources.first { $0.name == codec }!
        let src = try await Self.source(spec)
        let ffmpeg = try FFTools.ffmpegURL()
        let index = try await FrameIndexer.buildIndex(url: src)
        let containerStart = await MediaProbe.containerStartTime(url: src)

        #expect(index.keyframeFlags[100] && index.keyframeFlags[101])
        let decodeOrder = index.dts.indices.sorted { index.dts[$0] < index.dts[$1] }
        let at101 = try #require(decodeOrder.firstIndex(of: 101))
        #expect(decodeOrder[at101 - 1] == 100, "keyframe 100 must decode directly before 101")

        let plan = BoundaryReencodePlanner.plan(
            leadingCounts: CopySafeBoundaryDetector.leadingPictureCounts(
                keyframeFlags: index.keyframeFlags, dts: index.dts),
            frameCount: index.count, inFrame: 50, outFrame: 100)
        #expect(plan == [PlannedSegment(kind: .copy, range: 50..<101, outCutKeyframe: 101)])

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-b2bkey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let piece = try await BoundaryReencodeEngine.produceVideoPiece(
            ffmpeg, source: src, plan: plan, index: index,
            encoder: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], work: work, ext: ext,
            clipIndex: 0, codec: spec.codec, containerStart: containerStart)
        #expect(try await FrameIndexer.frameCount(url: piece) == 51)
    }
}
