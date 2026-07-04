import Testing
import Foundation
@testable import ClipStitcher

/// End-to-end regression net for the **truncated ending** repair (issue #79): a live capture
/// stopped mid-broadcast ends with a partial final frame, which the detector must report as a
/// real one-frame video damage zone (never zero-width) and Clip Doctor must repair by
/// *trimming* — the output ends on the last complete frame, decodes clean, and verifies clean.
///
/// **Owns no copyrighted bytes (ADR-0023).** It cuts a small slice on demand from a private
/// capture into a fully-gitignored folder, caches it there, and **skips loudly** when neither
/// the cached slice nor the capture is present (a fresh clone / other machine). It lives in its
/// own suite so the fast unit run excludes it with
/// `-skip-testing:ClipStitcherTests/TruncatedEndingRepairIntegrationTests`; run it on demand
/// with `-only-testing:ClipStitcherTests/TruncatedEndingRepairIntegrationTests`.
@Suite("Truncated-ending repair (integration)")
struct TruncatedEndingRepairIntegrationTests {

    /// Resolves the truncated-ending fixture without committing any copyrighted media.
    enum Fixture {
        enum FixtureError: Error { case absent }

        /// A developer-supplied capture whose recording stopped mid-broadcast — copyrighted,
        /// **never committed** (ADR-0023). Point `CLIPSTITCHER_TRUNCATED_CAPTURE` at one, or
        /// drop a slice at `Tests/Fixtures/truncated-ending/trunc_ending_slice.ts` (the folder
        /// is fully gitignored). Absent on a fresh clone, so the test skips loudly.
        static var capture: URL? {
            let fm = FileManager.default
            if let env = ProcessInfo.processInfo.environment["CLIPSTITCHER_TRUNCATED_CAPTURE"],
               !env.isEmpty {
                let url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
                if fm.fileExists(atPath: url.path) { return url }
            }
            return nil
        }

        static let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/truncated-ending", isDirectory: true)

        static let slice = folder.appendingPathComponent("trunc_ending_slice.ts")

        /// The cut recipe: a `-c copy` window over the **file end** (`-sseof`), which preserves
        /// the truncated final frame exactly — a slice from the middle would not (the recording
        /// only cut off at the true end). Stream-copy only, so the partial frame is untouched.
        static let sliceFromEnd = 15.0

        static var available: Bool {
            FileManager.default.fileExists(atPath: slice.path) || capture != nil
        }

        /// The cached slice, cut from the capture on demand (and cached) when absent. Throws
        /// `.absent` when neither the slice nor the capture exists.
        static func ensure() async throws -> URL {
            let fm = FileManager.default
            if fm.fileExists(atPath: slice.path) { return slice }
            guard let capture else { throw FixtureError.absent }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let ffmpeg = try FFTools.ffmpegURL()
            let result = try await ProcessRunner.run(ffmpeg, [
                "-v", "error", "-sseof", "-\(sliceFromEnd)", "-i", capture.path,
                "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-y", slice.path])
            guard result.status == 0 else { throw FixtureError.absent }
            return slice
        }
    }

    /// Doctoring a stopped-live-capture slice: the truncated ending is detected as a single
    /// real video zone reaching the file end, the repair trims to the last complete frame, the
    /// output decodes `-xerror` clean start-to-EOF, auto-verifies clean, is not padded with a
    /// fabricated tail, and never touches the source. Mirrors the import pipeline.
    @Test(.enabled(if: Fixture.available,
                   "truncated-ending capture absent — skipping (see ADR-0023)"))
    func doctorTrimsATruncatedEndingToACleanVerdict() async throws {
        let source = try await Fixture.ensure()

        let probe = try await MediaProbe.probe(url: source)
        let video = try #require(probe.video)
        let scan = try await FrameIndexer.scanAllStreams(url: source)
        let containerStart = await MediaProbe.containerStartTime(url: source)
        let zones = await DamageDetector.detectZones(
            url: source, scan: scan, containerStart: containerStart)
        let duration = try #require(probe.duration)

        // Preconditions: exactly the truncated-ending shape — a video zone reaching the file
        // end, never zero-width. If these drift, the assertions below would test nothing.
        let truncatedEnding = zones.first { $0.affectsVideo && $0.end >= duration - 1.0 }
        let ending = try #require(truncatedEnding, "no truncated-ending video zone was detected")
        #expect(ending.end > ending.start, "the truncated ending must never be zero-width")
        #expect(zones.allSatisfy { $0.end > $0.start }, "no zone may be zero-width (issue #79)")

        var clip = Clip(bookmark: Data(), displayName: source.lastPathComponent, video: video)
        clip.audioTracks = probe.audioTracks
        clip.duration = probe.duration
        clip.frameCount = scan.index.count
        clip.fieldCoded = FieldCodingDetector.isFieldCoded(
            packetPts: scan.index.pts,
            frameRates: [probe.video?.frameRate, probe.videoCodecFrameRate])
        clip.damageZones = zones

        let sourceSizeBefore = try Self.fileSize(source)
        let dest = Fixture.folder.appendingPathComponent("trunc_ending_repaired.ts")
        try? FileManager.default.removeItem(at: dest)
        defer { try? FileManager.default.removeItem(at: dest) }

        let result = try await ClipDoctorEngine.repair(
            source: source, clip: clip, index: scan.index, containerStart: containerStart,
            destination: dest, overwrite: true)

        // The headline acceptance: the truncated ending repairs to a clean verdict.
        #expect(result.verdict.clean, "verdict was not clean: \(result.verdict.message)")

        // The output ends on a complete frame: a full -xerror decode to EOF passes (the partial
        // final frame was trimmed, not baked in), and no corrupt entry seam.
        let ffmpeg = try FFTools.ffmpegURL()
        let decode = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", dest.path, "-f", "null", "-"])
        #expect(decode.status == 0,
                "repaired file failed -xerror decode: \(String(data: decode.stderr, encoding: .utf8) ?? "")")

        // Trimmed, not fps-filled with a fabricated tail: the output must not run materially
        // longer than the source (a full-tail fill regression would balloon it).
        let outDuration = try #require(await MediaProbe.probe(url: dest).duration)
        #expect(outDuration <= duration + 1.0,
                "output (\(outDuration) s) is longer than the source (\(duration) s) — the tail was filled, not trimmed")

        // Clip Doctor writes a sibling and never touches the source.
        #expect(try Self.fileSize(source) == sourceSizeBefore)
    }

    private static func fileSize(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }
}
