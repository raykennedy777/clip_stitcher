import Testing
import Foundation
@testable import ClipStitcher

/// The regression net for ADR-0026 (issue #106): a joined MKV records **one** reorder depth,
/// latched from its first piece, so every piece has to agree on it. When they don't, the final
/// stream-copy mux collapses frames onto duplicate timestamps and the decoder emits them early.
///
/// Both directions are asserted, because the two obvious fixes each break the other one:
/// - a **shallow** join (the reported bug) — a conform piece followed by a fully re-encoded
///   clip: everything the app encodes must be shallow, or the tail duplicates;
/// - a **deep** join — an interior cut on a B-pyramid source, where the copied middle is depth
///   2: the re-encoded head must keep its pyramid, or the copies duplicate.
///
/// Frame count, duration and audio are all correct in both defects, which is why only a
/// timestamp assertion catches them: every PTS must be present once and strictly increasing.
///
/// Owns no copyrighted bytes (ADR-0023): both sources are synthesised with ffmpeg's `lavfi`
/// into a temp dir. The target is H.264 with a real B-pyramid — the structure of nearly every
/// modern source — on a 12-frame GOP, so a cut inside one GOP plans as a single re-encode while
/// a wider cut plans copy-in-the-middle. Skips without
/// asserting when ffmpeg isn't reachable, like the sibling integration suites; run it alone with
/// `-only-testing:ClipStitcherTests/ReorderDepthIntegrationTests`.
@Suite("Reorder depth across a join (integration)", .serialized)
struct ReorderDepthIntegrationTests {

    /// `target`: 8 s of moving test pattern at 25 fps, H.264 at reorder depth 2 on a 12-frame
    /// GOP + AAC. The B-pyramid is pinned rather than left to the encoder's default: fixing the
    /// B-frame count (`b-adapt=0`, `scenecut=0`) makes x264 actually *build* pyramids on
    /// synthetic content, where its adaptive decision otherwise emits shallow cadences that
    /// declare depth 2 but never exercise it — the fixture would then pass whatever the app
    /// did. `fill`: 2 s of the same pattern as MPEG-2 (depth 1) + MP2, so it doesn't match the
    /// target and is conformed. nil when ffmpeg is unavailable.
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

    /// Every video PTS of a produced file, in the order the frames are emitted.
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

    /// The defect, stated as the invariant it breaks: each timestamp appears once, and they
    /// arrive in increasing order. A duplicate means two frames were collapsed onto one
    /// timestamp; an out-of-order pair means a frame was emitted early.
    private func expectDistinctAndIncreasing(_ pts: [Double], _ label: String) {
        let duplicates = pts.count - Set(pts).count
        #expect(duplicates == 0, "\(label): \(duplicates) duplicated timestamps of \(pts.count) frames")
        let backwards = zip(pts.dropFirst(), pts).filter { $0 <= $1 }.count
        #expect(backwards == 0, "\(label): \(backwards) frames emitted out of order")
    }

    /// The reported repro's shape (issue #106): a conformed fill, then a clip cut **inside one
    /// GOP** so its plan is a single re-encode and nothing is copied. Nothing in the join
    /// imposes a deep order, so every piece must be encoded shallow — with the pre-fix
    /// pyramid-by-default re-encode after the shallow conform, the tail duplicated.
    @Test func aShallowJoinOfConformThenReencodeKeepsEveryTimestamp() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }

        // Frames 26…34 sit inside the GOP starting at 24, so the plan is one re-encode.
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
        #expect(pts.count == 34)          // 25 conformed fill frames + 9 re-encoded
        expectDistinctAndIncreasing(pts, "shallow join")
    }

    /// The other direction: one clip, cut across GOPs, so the plan copies the keyframe-bounded
    /// middle of a **depth-2** source between two re-encoded edges. Flattening the app's
    /// encodes to depth 1 — the naive reading of the bug — makes the copied middle the deep
    /// piece behind a shallow head, and it duplicates instead.
    @Test func aDeepJoinOfReencodedEdgesAroundCopiedDepth2FramesKeepsEveryTimestamp() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let sources = try await Self.makeSources(in: dir) else { return }

        // Frames 20…159 span many whole GOPs, so the middle is copied — a long enough copied
        // run that a shallow head really does collapse timestamps in it (22 duplicates of 140
        // frames, measured); both edges are partial GOPs and re-encode.
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

        // And the file really is the deep case — the copied frames kept their source's depth,
        // so the join (and the re-encoded edges in it) had to declare 2, not 1.
        let ffprobe = try FFTools.ffprobeURL()
        let depth = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=has_b_frames", "-of", "csv=p=0", output.path])
        #expect((String(data: depth.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("2"))
    }
}
