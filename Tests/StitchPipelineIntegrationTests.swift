import Testing
import Foundation
@testable import ClipStitcher

/// End-to-end net for the headless CLI pipeline (issue #105): a Stitch Job JSON in,
/// a stitched MKV out, through the exact `StitchPipeline.run` the `clipstitch` binary
/// calls — probe, index, plan, conform, export. The unit suite pins the contract's
/// pure decisions; this proves they compose into a real file with the right frames
/// and the right audio.
///
/// Owns no copyrighted bytes (ADR-0023): both sources are synthesised with ffmpeg's
/// `lavfi` into a temp dir — a red H.264 target and a blue MPEG-2 fill whose codecs
/// deliberately differ, so the run exercises both video treatments (the target
/// stream-copies its keyframe-bounded middle, the fill conforms to the target spec,
/// ADR-0011). Colors make content assertable per frame; the fill's two audio streams
/// (silence, then a tone) make the per-clip audio selection assertable by level.
/// Skips without asserting when ffmpeg isn't reachable, like the sibling
/// integration suites; run it alone with
/// `-only-testing:ClipStitcherTests/StitchPipelineIntegrationTests`.
@Suite("Stitch pipeline (integration)", .serialized)
struct StitchPipelineIntegrationTests {

    /// The two synthetic sources, or nil when ffmpeg isn't available (the suite then
    /// skips). `target`: 2 s of red at 25 fps, H.264 (12-frame GOP so an interior cut
    /// exercises the boundary re-encode) + one 440 Hz AAC stream. `fill`: 1 s of blue,
    /// MPEG-2 + two MP2 streams — stream 0 silence, stream 1 an 880 Hz tone — so a
    /// job selecting stream 1 is distinguishable from the default by level alone.
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

    /// 1 s of green HEVC + one AAC stream, or nil when this ffmpeg has no libx265 — the
    /// third format the engine supports (MPEG-2, H.264, HEVC), so the plan query is proved
    /// on all three rather than on the two the older case happened to use.
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

    /// The RGB of one output frame's first pixel. Decoded to a temp *file*, never to
    /// stdout: a raw 320×240 frame is ~230 KB, and `ProcessRunner` without a stdout
    /// sink only drains the pipe at termination — ffmpeg would fill the ~64 KB pipe
    /// buffer and deadlock mid-write.
    private func firstPixel(ffmpeg: URL, file: URL, frame: Int, scratch: URL) async throws -> (r: UInt8, g: UInt8, b: UInt8)? {
        let raw = scratch.appendingPathComponent("frame\(frame).rgb")
        let result = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-i", file.path,
            "-vf", "select=eq(n\\,\(frame))", "-frames:v", "1",
            "-f", "rawvideo", "-pix_fmt", "rgb24", "-y", raw.path])
        guard result.status == 0, let data = try? Data(contentsOf: raw), data.count >= 3 else { return nil }
        return (data[0], data[1], data[2])
    }

    /// `volumedetect`'s mean level over a window of the output's first audio track —
    /// how the fill's selected-vs-silent stream is told apart post-encode.
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

        // Frames [5, 44] of the 50-frame target (an interior cut on a 12-frame GOP:
        // both boundary re-encodes exercised) + the whole 25-frame fill, whose audio
        // is its tone stream, not its silent default.
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

        // Frame count: 40 kept target frames + 25 conformed fill frames, exactly.
        guard let ffprobe = try? FFTools.ffprobeURL() else { return }
        let count = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0", "-count_frames",
            "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", output.path])
        #expect(count.status == 0)
        let frames = Int((String(data: count.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(frames == 65)

        // Content: a frame in the target's span is red, one past the join is blue —
        // the conform really produced the fill's picture, in the target's codec.
        let inTarget = try await firstPixel(ffmpeg: ffmpeg, file: output, frame: 10, scratch: dir)
        #expect((inTarget?.r ?? 0) > 200 && (inTarget?.g ?? 255) < 60 && (inTarget?.b ?? 255) < 60)
        let inFill = try await firstPixel(ffmpeg: ffmpeg, file: output, frame: 50, scratch: dir)
        #expect((inFill?.b ?? 0) > 200 && (inFill?.r ?? 255) < 60 && (inFill?.g ?? 255) < 60)

        // Audio selection: the fill's span carries its stream-1 tone — audibly above
        // silence. If the selection were ignored (stream 0), this window would be
        // digital silence (≈ -91 dB); the tone means ~-21 dB. -50 splits them safely.
        let level = try await meanVolume(ffmpeg: ffmpeg, file: output, start: 1.7, duration: 0.8)
        let unwrapped = try #require(level)
        #expect(unwrapped > -50)

        // And the video is the target's codec throughout (one stream, h264).
        let codec = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name", "-of", "csv=p=0", output.path])
        #expect((String(data: codec.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "h264")
    }

    /// The plan query's promise (issue #115): what `--plan` says the job will produce is
    /// what the export then produces. Same job, same `prepare` — the report's per-clip
    /// `expectedFrames` must sum to the frame count of the file `run` writes, or an agent
    /// that plans instead of rendering is reading a number that means nothing.
    @Test func planReportPredictsTheFrameCountTheExportWrites() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }

        // All three formats the engine supports in one job (the issue's "Done when"):
        // an H.264 target, an MPEG-2 fill and an HEVC fill, both fills conformed.
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

        // The plan itself: a smart-rendered target cut between keyframes, conformed fills
        // (MPEG-2 and HEVC against an H.264 target), and one audio track out.
        #expect(report.version == PlanReport.contractVersion)
        #expect(report.target == 0)
        #expect(report.clips.map(\.treatment)
                == [.smartRender, .conform] + (hevc == nil ? [] : [.conform]))
        #expect(report.clips[0].segments?.contains { $0.kind == .copy } == true)
        #expect(report.clips[0].copySafeKeyframes?.afterIn != nil)
        #expect(report.clips[1].reason?.contains { $0.property == "Codec" } == true)
        #expect(report.audio.bitrate.out == ExportEngine.audioBitrate)

        // And it round-trips as JSON with every key a reader indexes.
        let decoded = try JSONDecoder().decode(PlanReport.self, from: report.jsonData())
        #expect(decoded == report)

        // The promise: sum of expectedFrames == the frames the export writes.
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

    /// The index cache's plan-level promise (R2 of the 2026 R16 review): a plan made from
    /// cached facts is byte-for-byte the plan a fresh scan makes, the second run reads every
    /// source from the cache, and a changed source is scanned again.
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

        // A source rewritten in place is scanned again; the others still hit.
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

    /// Every stream's packets as the container carries them: a framemd5 of the stream-copied
    /// packets, plus each packet's stream, pts, dts, size and flags. Whole-file bytes differ
    /// between two Matroska writes of the same streams (a random SegmentUID and DateUTC),
    /// so identity is compared at this level.
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

    /// The piece cache's identity promise (R1 of the 2026 R16 review): a render that takes
    /// every re-encoded piece from the cache writes the same streams, packet for packet, as
    /// the render that made them — and that render writes what an uncached render writes.
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

        // Target head + tail, and one conform per fill.
        let encodes = 2 + (hevc == nil ? 1 : 2)
        #expect(coldLog.lines.contains("Piece cache: 0 hits, \(encodes) misses"))
        #expect(warmLog.lines.contains("Piece cache: \(encodes) hits, 0 misses"))
        let warmEncodes = warmLog.lines.filter { $0.contains(" reEncode [") || $0.contains(" conform: ") }
        #expect(warmEncodes.count == encodes)
        #expect(warmEncodes.allSatisfy { $0.hasSuffix("piece cache hit") })
        // A hit is verified like a fresh piece.
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

    /// The piece cache's incremental promise: moving one clip's in point re-encodes only the
    /// piece that edge touches. The other clip's two edges, the conform and the moved clip's
    /// own unchanged tail all come from the cache.
    @Test func movingOneMarkReEncodesOnlyThePieceItTouches() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }
        let cacheDir = dir.appendingPathComponent("pieces")
        // Keyframes every 12 frames: clip 2 [3, 30] plans reEncode [3,12) · copy [12,24) ·
        // reEncode [24,31); moving its in point to 7 changes only the head.
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

        // And the edited render is the render an uncached run of the edited job writes.
        let uncached = dir.appendingPathComponent("uncached.mkv")
        _ = try await StitchPipeline.run(job: try Self.job(sources, extra: third(7)), output: uncached)
        let a = try await Self.streamFingerprint(warm), b = try await Self.streamFingerprint(uncached)
        #expect(a.md5 == b.md5)
        #expect(a.packets == b.packets)
    }

    /// Collects the pipeline's stage lines, which arrive on whatever task logs them.
    final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Every stage of a render names its elapsed time (R5 of the 2026 R16 review), so a
    /// slow run's log says which stage held it: the probe, the index scan with its packet
    /// count, the damage scan with its candidates, the plan, each segment run and verify,
    /// the conform, the join, the audio mux and its verify, and the run's total.
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

        // Stream 5 doesn't exist in the fill — the post-probe check refuses with the
        // job-class error (the CLI's exit 65), never a silent silence-fill.
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
