import Testing
import Foundation
@testable import ClipStitcher

/// Ungated coverage of `ClipDoctorEngine.repair` orchestration (issue #63). The only
/// end-to-end repair exercise that existed was `FieldCodedRepairIntegrationTests`, which
/// skips on any machine/CI without a private PAFF capture (ADR-0023) — so on a fresh public
/// clone the whole repair pipeline (the pre-flight guards, plan routing, the staged atomic
/// move, the source-untouched guarantee, and the auto-verify wiring) had zero coverage.
///
/// Two layers, both ungated:
///   - The pre-flight **guards** throw before ffmpeg is ever located, so they need no media
///     and run instantly.
///   - The **orchestration** test synthesises a tiny progressive H.264 + MP2 source with
///     `ffmpeg -f lavfi` (CI installs ffmpeg) and runs a real repair end-to-end — covering
///     the progressive smart-render route, `produceVideoPiece`, the in-codec audio rebuild,
///     the atomic move into place, and the clean auto-verify verdict. No media is committed
///     (ADR-0023): the source is generated into a throwaway temp dir and removed after.
struct ClipDoctorRepairTests {

    // MARK: - Pre-flight guards (no ffmpeg — throw before FFTools.ffmpegURL())

    private func videoClip(codec: String = "h264", fieldCoded: Bool = false) -> Clip {
        var clip = Clip(bookmark: Data(), displayName: "race.ts")
        clip.video = VideoProperties(codec: codec, width: 320, height: 240,
                                     frameRate: "25/1", pixelFormat: "yuv420p")
        clip.fieldCoded = fieldCoded
        return clip
    }

    private var dummyIndex: FrameIndex {
        FrameIndex(pts: [0, 0.04, 0.08], keyframeFlags: [true, false, false])
    }

    /// A clip with no probed video can't be planned — the first guard refuses it.
    @Test func repairWithoutVideoIsAnInvalidPlan() async {
        var clip = videoClip()
        clip.video = nil
        await #expect(throws: ExportError.self) {
            try await ClipDoctorEngine.repair(
                source: URL(fileURLWithPath: "/x/in.ts"), clip: clip,
                index: dummyIndex, containerStart: 0)
        }
    }

    /// A field-coded source whose codec isn't H.264 is refused before any work — the
    /// damage-to-EOF tail is always MBAFF H.264, so a non-H.264 head would ship a
    /// mixed-codec concat (issue #57). This is the field-coded branch of plan routing.
    @Test func fieldCodedNonH264IsRefusedUpFront() async {
        let clip = videoClip(codec: "hevc", fieldCoded: true)
        do {
            _ = try await ClipDoctorEngine.repair(
                source: URL(fileURLWithPath: "/x/in.ts"), clip: clip,
                index: dummyIndex, containerStart: 0)
            Issue.record("expected unsupportedFieldCodedCodec")
        } catch ClipDoctorEngine.DoctorError.unsupportedFieldCodedCodec(let codec) {
            #expect(codec == "hevc")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    /// Clip Doctor never writes over its own source: a destination equal to the source
    /// is refused (the source-untouched guarantee, first half).
    @Test func aDestinationEqualToTheSourceIsRefused() async {
        let source = URL(fileURLWithPath: "/x/in.ts")
        do {
            _ = try await ClipDoctorEngine.repair(
                source: source, clip: videoClip(), index: dummyIndex,
                containerStart: 0, destination: source)
            Issue.record("expected destinationIsSource")
        } catch ClipDoctorEngine.DoctorError.destinationIsSource {
            // expected
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    /// An existing destination is not clobbered without `overwrite` — the second half of
    /// the source-untouched guarantee (a prior `_repaired` file is preserved).
    @Test func anExistingDestinationIsNotClobberedWithoutOverwrite() async throws {
        let fm = FileManager.default
        let dest = fm.temporaryDirectory.appendingPathComponent("cs63-existing-\(UUID().uuidString).ts")
        fm.createFile(atPath: dest.path, contents: Data("keep me".utf8))
        defer { try? fm.removeItem(at: dest) }

        do {
            _ = try await ClipDoctorEngine.repair(
                source: URL(fileURLWithPath: "/x/in.ts"), clip: videoClip(),
                index: dummyIndex, containerStart: 0, destination: dest, overwrite: false)
            Issue.record("expected destinationExists")
        } catch ClipDoctorEngine.DoctorError.destinationExists(let url) {
            #expect(url == dest)
        } catch {
            Issue.record("wrong error: \(error)")
        }
        // The pre-existing file is untouched.
        #expect(try String(contentsOf: dest, encoding: .utf8) == "keep me")
    }

    // MARK: - End-to-end orchestration (synthetic source, real repair)

    /// A progressive H.264 source with one damage zone repairs to a clean verdict: the
    /// smart-render route copies the clean spans, re-encodes the zone, rebuilds audio in
    /// its own codec, atomically moves the result into place, and re-scans clean — all
    /// without touching the source. Covers the orchestration the gated PAFF test can't on CI.
    @Test func progressiveRepairProducesACleanVerifiedSiblingWithoutTouchingTheSource() async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cs63-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // A 4 s, 25 fps, 1 s-GOP H.264 + MP2 transport stream. Closed GOP (sc_threshold 0,
        // fixed keyint) so the copy spans split predictably; an honest TS start_time.
        let source = work.appendingPathComponent("source.ts")
        let ffmpeg = try FFTools.ffmpegURL()
        let made = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=4",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "25", "-keyint_min", "25",
            "-sc_threshold", "0", "-c:a", "mp2", "-b:a", "128k",
            "-f", "mpegts", source.path])
        try #require(made.status == 0,
                     "fixture generation failed: \(String(data: made.stderr, encoding: .utf8) ?? "")")

        // Mirror the import pipeline (ProjectDocument.importClip).
        let probe = try await MediaProbe.probe(url: source)
        let video = try #require(probe.video)
        #expect(video.codec == "h264")
        let scan = try await FrameIndexer.scanAllStreams(url: source)
        let containerStart = await MediaProbe.containerStartTime(url: source)

        var clip = Clip(bookmark: Data(), displayName: source.lastPathComponent, video: video)
        clip.audioTracks = probe.audioTracks
        clip.duration = probe.duration
        clip.frameCount = scan.index.count
        clip.fieldCoded = false
        // One interior video damage zone: forces a copy → re-encode → copy plan so the
        // smart-render splice (produceVideoPiece concat + self-verify) actually runs. The
        // content is clean, so the re-scan must come back clean.
        clip.damageZones = [DamageZone(start: 1.5, end: 2.0, affectsVideo: true)]

        let sourceSizeBefore = try Self.fileSize(source)
        let dest = work.appendingPathComponent("source_repaired.ts")

        let result = try await ClipDoctorEngine.repair(
            source: source, clip: clip, index: scan.index, containerStart: containerStart,
            destination: dest, overwrite: true)

        // Auto-verify wiring: a clean source re-scans clean.
        #expect(result.verdict.clean, "verdict was not clean: \(result.verdict.message)")
        #expect(result.repairedZoneCount == 1)

        // The staged atomic move landed a real, decodable sibling carrying the MP2 track.
        #expect(fm.fileExists(atPath: dest.path))
        let outProbe = try await MediaProbe.probe(url: dest)
        #expect(outProbe.video?.codec == "h264")
        #expect(outProbe.audioTracks.contains { $0.codec == "mp2" })
        let decode = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", dest.path, "-f", "null", "-"])
        #expect(decode.status == 0,
                "repaired file failed -xerror decode: \(String(data: decode.stderr, encoding: .utf8) ?? "")")

        // The source is never written to.
        #expect(try Self.fileSize(source) == sourceSizeBefore)
    }

    private static func fileSize(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }
}
