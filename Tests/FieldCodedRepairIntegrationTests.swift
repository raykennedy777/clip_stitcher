import Testing
import Foundation
@testable import ClipStitcher

/// End-to-end regression net for the field-coded (PAFF) damage-to-EOF repair (issue #54,
/// ADR-0022) — the one acceptance criterion that the fast unit suite can't cover, because
/// it needs a *real* field-coded source: the encoders on this machine are MBAFF-only, so a
/// PAFF fixture can't be synthesised (the whole reason #54 is a re-encode). The per-piece
/// frame-count/timestamp gates are deliberately dropped for the field-coded piece, and a
/// failed re-scan is "keep the file, inconclusive" — never a hard failure — so without this
/// test a future change could silently break the PAFF repair with nothing to catch it.
///
/// **Owns no copyrighted bytes (ADR-0023).** It cuts a small slice on demand from a private
/// capture into a fully-gitignored folder, caches it there, and **skips loudly** when neither
/// the cached slice nor the capture is present (a fresh clone / other machine). It is kept
/// out of the everyday run by living in its own suite — run it on demand with
/// `-only-testing:ClipStitcherTests/FieldCodedRepairIntegrationTests`, and the fast unit run
/// excludes it with `-skip-testing:ClipStitcherTests/FieldCodedRepairIntegrationTests`.
@Suite("Field-coded repair (integration)")
struct FieldCodedRepairIntegrationTests {

    /// Resolves the PAFF fixture without committing any copyrighted media (ADR-0023).
    enum PAFFFixture {
        enum FixtureError: Error { case absent }

        /// A developer-supplied field-coded capture — copyrighted, **never committed**
        /// (ADR-0023). Point `CLIPSTITCHER_PAFF_CAPTURE` at one, or drop a file at
        /// `Tests/Fixtures/field-coded/source.ts` (the folder is fully gitignored). Absent on a
        /// fresh clone, so the test skips loudly. Returns nil unless a capture actually exists.
        static var capture: URL? {
            let fm = FileManager.default
            if let env = ProcessInfo.processInfo.environment["CLIPSTITCHER_PAFF_CAPTURE"],
               !env.isEmpty {
                let url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
                if fm.fileExists(atPath: url.path) { return url }
            }
            let local = folder.appendingPathComponent("source.ts")
            return fm.fileExists(atPath: local.path) ? local : nil
        }

        /// The gitignored local fixtures folder, located relative to *this source file*
        /// (`#filePath`, a compile-time absolute path) rather than from the environment or the
        /// working directory — neither reaches the test runner (memory headless-verification).
        static let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                     // Tests/
            .appendingPathComponent("Fixtures/field-coded", isDirectory: true)

        static let slice = folder.appendingPathComponent("paff_slice.ts")

        /// The cut recipe: a fast `-c copy` window over the capture's first damage zone
        /// (~883 s, ADR-0022), so the slice is field-coded **and** carries a video damage zone —
        /// the head copies clean and the MBAFF tail re-encodes from the seam. Stream-copy only,
        /// no re-encode, so the corrupt packets are preserved exactly.
        static let sliceStart = 850.0, sliceDuration = 90.0

        /// The fixture can run iff the cached slice or a developer-supplied capture is present.
        static var available: Bool {
            FileManager.default.fileExists(atPath: slice.path) || capture != nil
        }

        /// The cached slice, cut from the capture on demand (and cached in the gitignored
        /// folder) when absent. Throws `.absent` when neither the slice nor the capture exists.
        static func ensure() async throws -> URL {
            let fm = FileManager.default
            if fm.fileExists(atPath: slice.path) { return slice }
            guard let capture else { throw FixtureError.absent }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let ffmpeg = try FFTools.ffmpegURL()
            let result = try await ProcessRunner.run(ffmpeg, [
                "-v", "error", "-ss", String(sliceStart), "-i", capture.path,
                "-t", String(sliceDuration),
                "-map", "0:v:0", "-map", "0:a:0", "-map", "0:a:1",
                "-c", "copy", "-y", slice.path])
            guard result.status == 0 else { throw FixtureError.absent }
            return slice
        }
    }

    /// Doctoring a field-coded source produces a `_repaired` file that auto-verifies clean
    /// (the #54 headline), keeps both MP2 audio tracks, decodes `-xerror` start-to-EOF, and
    /// never touches the source. Mirrors the import pipeline (`ProjectDocument.importClip`):
    /// probe → full-stream index → field-coded cadence check → container start → damage
    /// detection → `ClipDoctorEngine.repair`.
    @Test(.enabled(if: PAFFFixture.available,
                   "PAFF capture absent — skipping field-coded repair integration test (see ADR-0023)"))
    func doctorRepairsAFieldCodedSliceToACleanVerdict() async throws {
        let source = try await PAFFFixture.ensure()

        let probe = try await MediaProbe.probe(url: source)
        let video = try #require(probe.video)
        let scan = try await FrameIndexer.scanAllStreams(url: source)
        let containerStart = await MediaProbe.containerStartTime(url: source)
        let zones = await DamageDetector.detectZones(
            url: source, scan: scan, containerStart: containerStart)
        let fieldCoded = FieldCodingDetector.isFieldCoded(
            packetPts: scan.index.pts,
            frameRates: [probe.video?.frameRate, probe.videoCodecFrameRate])

        // Preconditions that make this a genuine PAFF damage-to-EOF exercise — if any fails,
        // the slice recipe drifted and the assertions below would test nothing.
        let hasVideoZone = zones.contains(where: \.affectsVideo)
        #expect(fieldCoded, "the slice must be field-coded (PAFF) to exercise the MBAFF route")
        #expect(video.codec == "h264")
        #expect(hasVideoZone, "the slice must carry a video damage zone")

        var clip = Clip(bookmark: Data(), displayName: source.lastPathComponent, video: video)
        clip.audioTracks = probe.audioTracks
        clip.duration = probe.duration
        clip.frameCount = scan.index.count
        clip.fieldCoded = fieldCoded
        clip.damageZones = zones

        let sourceSizeBefore = try Self.fileSize(source)

        let dest = PAFFFixture.folder.appendingPathComponent("paff_slice_repaired.ts")
        try? FileManager.default.removeItem(at: dest)
        defer { try? FileManager.default.removeItem(at: dest) }

        let result = try await ClipDoctorEngine.repair(
            source: source, clip: clip, index: scan.index, containerStart: containerStart,
            destination: dest, overwrite: true)

        // The headline #54 acceptance: a field-coded source repairs to a clean verdict.
        #expect(result.verdict.clean, "verdict was not clean: \(result.verdict.message)")

        // Both MP2 audio tracks survive into the repaired output, in their own codec.
        let outProbe = try await MediaProbe.probe(url: dest)
        let allMP2 = outProbe.audioTracks.allSatisfy { $0.codec == "mp2" }
        #expect(outProbe.audioTracks.count == 2)
        #expect(allMP2)

        // The repaired file decodes -xerror clean from start to EOF (no corrupt entry seam).
        let ffmpeg = try FFTools.ffmpegURL()
        let decode = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", dest.path, "-f", "null", "-"])
        #expect(decode.status == 0,
                "repaired file failed -xerror decode: \(String(data: decode.stderr, encoding: .utf8) ?? "")")

        // Clip Doctor writes a sibling and never touches the source.
        #expect(try Self.fileSize(source) == sourceSizeBefore)
    }

    private static func fileSize(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }
}
