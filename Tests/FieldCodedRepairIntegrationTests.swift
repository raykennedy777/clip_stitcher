import Testing
import Foundation
@testable import ClipStitcher

@Suite("Field-coded repair (integration)")
struct FieldCodedRepairIntegrationTests {
    enum PAFFFixture {
        enum FixtureError: Error { case absent }

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

        static let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/field-coded", isDirectory: true)

        static let slice = folder.appendingPathComponent("paff_slice.ts")

        static let sliceStart = 850.0, sliceDuration = 90.0

        static var available: Bool {
            FileManager.default.fileExists(atPath: slice.path) || capture != nil
        }

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

        #expect(result.verdict.clean, "verdict was not clean: \(result.verdict.message)")

        let outProbe = try await MediaProbe.probe(url: dest)
        let allMP2 = outProbe.audioTracks.allSatisfy { $0.codec == "mp2" }
        #expect(outProbe.audioTracks.count == 2)
        #expect(allMP2)

        let ffmpeg = try FFTools.ffmpegURL()
        let decode = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", dest.path, "-f", "null", "-"])
        #expect(decode.status == 0,
                "repaired file failed -xerror decode: \(String(data: decode.stderr, encoding: .utf8) ?? "")")

        #expect(try Self.fileSize(source) == sourceSizeBefore)
    }

    private static func fileSize(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }
}
