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
