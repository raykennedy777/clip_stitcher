import Testing
import Foundation
@testable import ClipStitcher

@Suite("Open-GOP in-point splice (integration)", .serialized)
struct OpenGopInPointIntegrationTests {
    static let frameCount = 1500
    static let headOut = 299
    static let inPoint = 630
    static let keyframe = 750
    static let splicedPlan = [PlannedSegment(kind: .reEncode, range: inPoint..<keyframe),
                              PlannedSegment(kind: .copy, range: keyframe..<frameCount,
                                             droppedLeadingPictures: 1)]

    static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/open-gop-in-point")
    }

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-opengop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func source(_ ext: String = "mkv") async throws -> URL {
        let master = try await masterSource()
        guard ext != "mkv" else { return master }
        let url = fixtureDirectory.appendingPathComponent("open_gop_x265_main10.\(ext)")
        if FileManager.default.exists(url) { return url }
        let made = try await ProcessRunner.run(try FFTools.ffmpegURL(), [
            "-v", "error", "-y", "-i", master.path, "-c", "copy", url.path])
        guard made.status == 0 else {
            throw ExportError.cutFailed(String(data: made.stderr, encoding: .utf8) ?? "")
        }
        return url
    }

    static func masterSource() async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try "*\n!.gitignore\n".write(to: fixtureDirectory.appendingPathComponent(".gitignore"),
                                     atomically: true, encoding: .utf8)
        let url = fixtureDirectory.appendingPathComponent("open_gop_x265_main10.mkv")
        if fm.exists(url) { return url }
        let made = try await ProcessRunner.run(try FFTools.ffmpegURL(), [
            "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=50",
            "-frames:v", String(frameCount), "-c:v", "libx265", "-pix_fmt", "yuv420p10le",
            "-x265-params", "keyint=250:scenecut=0:log-level=error", url.path])
        guard made.status == 0 else {
            throw ExportError.cutFailed(String(data: made.stderr, encoding: .utf8) ?? "")
        }
        return url
    }

    static func job(_ src: URL, ext: String) throws -> StitchJob {
        try StitchJob.parse(Data("""
        {
          "version": 1,
          "clips": [
            { "path": "\(src.path)", "inFrame": 0, "outFrame": \(headOut), "target": true },
            { "path": "\(src.path)", "inFrame": \(inPoint) }
          ],
          "output": { "container": "\(ext)", "type": "videoOnly" }
        }
        """.utf8))
    }

    @Test(arguments: [("mkv", "mkv"), ("mkv", "mp4"), ("mkv", "ts"), ("ts", "mkv"), ("mp4", "mp4")])
    func aMidGopInPointSplicesFrameExactly(sourceExt: String, ext: String) async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let src = try await Self.source(sourceExt)
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = try Self.job(src, ext: ext)

        let prepared = try await StitchPipeline.prepare(job: job)
        #expect(prepared.items[1].segments == Self.splicedPlan)

        let output = dir.appendingPathComponent("out.\(ext)")
        let log = StitchPipelineIntegrationTests.LineSink()
        _ = try await StitchPipeline.run(job: job, output: output, log: { log.append($0) })
        #expect(!log.lines.contains { $0.contains("splice refused") },
                "the splice fell back: \(log.lines)")

        let sourceFrames = Array(0...Self.headOut) + Array(Self.inPoint..<Self.frameCount)
        let seam = Self.headOut + 1 + (Self.keyframe - Self.inPoint)
        let defects = try await Self.seamDefects(ffmpeg, output: output, source: src,
                                                 sourceFrames: sourceFrames, seam: seam)
        #expect(defects.isEmpty, "\(defects)")
        let shifted = try await Self.seamDefects(ffmpeg, output: output, source: src,
                                                 sourceFrames: sourceFrames.map { $0 + 1 },
                                                 seam: seam)
        #expect(shifted.contains { $0.hasPrefix("frame match") }, "\(shifted)")
        #expect(try await Self.nalTypes(ffmpeg, output).contains(OpenGopSplice.blaNoLeading))
    }

    @Test func withTheDropOffTheChecksSeeTheOrphanedLeadingPicture() async throws {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let src = try await Self.source()
        let work = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: work) }
        let index = try await FrameIndexer.buildIndex(url: src)
        let probe = try await MediaProbe.probe(url: src)
        let encoder = BoundaryReencodeEngine.reencodeVideoArgs(
            codec: "hevc", profile: probe.video?.profile, pixelFormat: probe.video?.pixelFormat,
            fieldOrder: probe.video?.fieldOrder, bitrate: probe.video?.bitrate)
        await #expect(throws: ExportError.self) {
            _ = try await BoundaryReencodeEngine.produceVideoPiece(
                ffmpeg, source: src, plan: Self.splicedPlan, index: index, encoder: encoder,
                work: work, ext: "ts", clipIndex: 0, codec: "hevc",
                containerStart: await MediaProbe.containerStartTime(url: src),
                frameRate: probe.video?.frameRate, reorderDepth: probe.video?.reorderDepth,
                inPointSplice: false)
        }
        let piece = work.appendingPathComponent("c0_joined.ts")
        #expect(FileManager.default.exists(piece))
        let defects = try await Self.seamDefects(
            ffmpeg, output: piece, source: src,
            sourceFrames: Array(Self.inPoint..<Self.frameCount), seam: Self.keyframe - Self.inPoint)
        #expect(defects.contains { $0.hasPrefix("frame count: 871 packets") }, "\(defects)")
        #expect(defects.contains { $0.hasPrefix("decode") }, "\(defects)")
    }

    static func seamDefects(_ ffmpeg: URL, output: URL, source: URL, sourceFrames: [Int],
                            seam: Int) async throws -> [String] {
        var defects: [String] = []
        let packets = try await FrameIndexer.frameCount(url: output)
        let out = try await grayFrames(ffmpeg, output)
        if packets != sourceFrames.count || out.count != sourceFrames.count {
            defects.append("frame count: \(packets) packets, \(out.count) decoded, \(sourceFrames.count) planned")
        }

        do {
            try await BoundaryReencodeEngine.decodeCheck(
                ffmpeg, output, failureLabel: "The spliced output did not decode silently.",
                requireSilentDecode: true,
                at: VerificationLocation(clipIndex: 0, piece: output.lastPathComponent, plan: []))
        } catch {
            defects.append("decode: \(String(describing: error).prefix(400))")
        }

        let timing = try await packetTiming(output)
        let order = timing.sorted { $0.pts < $1.pts }
        if seam < order.count {
            let seamPts = order[seam].pts
            let decode = timing.sorted { $0.dts < $1.dts }
            let interval = (order[order.count - 1].pts - order[0].pts) / Double(order.count - 1)
            if let at = decode.firstIndex(where: { abs($0.pts - seamPts) < interval / 4 }) {
                let near = decode[max(0, at - 10)..<min(decode.count, at + 11)]
                let steps = zip(near.dropFirst(), near).map { $0.dts - $1.dts }
                let durations = near.compactMap(\.duration)
                if steps.contains(where: { abs($0 - interval) > 0.0005 })
                    || durations.contains(where: { abs($0 - interval) > 0.0005 }) {
                    defects.append("seam timing: DTS steps \(steps), durations \(durations)")
                }
            }
        }

        let src = try await grayFrames(ffmpeg, source)
        var misplaced: [String] = []
        for i in max(0, seam - 300)..<min(out.count, sourceFrames.count, seam + 300) {
            let want = sourceFrames[i]
            guard want < src.count else { misplaced.append("\(i):\(want)→none"); continue }
            let nearest = (max(0, want - 8)...min(src.count - 1, want + 8)).min {
                distance(out[i], src[$0]) < distance(out[i], src[$1])
            }
            if nearest != want { misplaced.append("\(i):\(want)→\(nearest ?? -1)") }
        }
        if !misplaced.isEmpty {
            defects.append("frame match: \(misplaced.count) frames misplaced, first \(misplaced.prefix(6))")
        }

        let outMD5 = try await decodedMD5(ffmpeg, output)
        let srcMD5 = try await decodedMD5(ffmpeg, source)
        let away = (seam + 250)..<min(outMD5.count, sourceFrames.count)
        let differing = away.filter {
            sourceFrames[$0] >= srcMD5.count || outMD5[$0] != srcMD5[sourceFrames[$0]]
        }
        if away.isEmpty || !differing.isEmpty {
            defects.append("copied frames: \(differing.count) of \(away.count) differ from the source")
        }
        return defects
    }

    static func packetTiming(_ file: URL) async throws
        -> [(pts: Double, dts: Double, duration: Double?)] {
        let csv = try await toolOutput(try FFTools.ffprobeURL(), [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "packet=pts_time,dts_time,duration_time", "-of", "csv=p=0", file.path])
        return (String(data: csv, encoding: .utf8) ?? "").split(separator: "\n").compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, let pts = Double(f[0]) else { return nil }
            return (pts, Double(f[1]) ?? pts, f.count > 2 ? Double(f[2]) : nil)
        }
    }

    static func grayFrames(_ ffmpeg: URL, _ file: URL) async throws -> [[UInt8]] {
        let raw = try await toolOutput(ffmpeg, [
            "-v", "error", "-i", file.path, "-map", "0:v:0", "-fps_mode", "passthrough",
            "-vf", "scale=64:48,format=gray", "-f", "rawvideo", "-"])
        let size = 64 * 48
        return stride(from: 0, to: raw.count - size + 1, by: size).map {
            [UInt8](raw[$0..<$0 + size])
        }
    }

    static func toolOutput(_ tool: URL, _ args: [String]) async throws -> Data {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-opengop-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await ProcessRunner.run(tool, args, stdoutTo: file)
        return try Data(contentsOf: file)
    }

    static func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var sum = 0
        for i in a.indices { let d = Int(a[i]) - Int(b[i]); sum += d * d }
        return sum
    }

    static func decodedMD5(_ ffmpeg: URL, _ file: URL) async throws -> [String] {
        let dump = try await toolOutput(ffmpeg, [
            "-v", "error", "-i", file.path, "-map", "0:v:0", "-fps_mode", "passthrough",
            "-f", "framemd5", "-"])
        return (String(data: dump, encoding: .utf8) ?? "").split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .compactMap { $0.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    static func nalTypes(_ ffmpeg: URL, _ file: URL) async throws -> Set<Int> {
        let traceFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-opengop-trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: traceFile) }
        _ = try await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-i", file.path, "-map", "0:v:0", "-c", "copy",
            "-bsf:v", "trace_headers", "-f", "null", "-"], stderrTo: traceFile)
        let text = (try? String(contentsOf: traceFile, encoding: .utf8)) ?? ""
        var types: Set<Int> = []
        for line in text.split(separator: "\n") where line.contains("nal_unit_type") {
            if let value = line.split(separator: "=").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                types.insert(value)
            }
        }
        return types
    }
}

private extension FileManager {
    func exists(_ url: URL) -> Bool { fileExists(atPath: url.path) }
}
