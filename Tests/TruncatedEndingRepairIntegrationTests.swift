import Testing
import Foundation
@testable import ClipStitcher

@Suite("Truncated-ending repair (integration)")
struct TruncatedEndingRepairIntegrationTests {
    enum Fixture {
        enum FixtureError: Error { case absent }

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

        static let sliceFromEnd = 15.0

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
                "-v", "error", "-sseof", "-\(sliceFromEnd)", "-i", capture.path,
                "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-y", slice.path])
            guard result.status == 0 else { throw FixtureError.absent }
            return slice
        }
    }

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

        #expect(result.verdict.clean, "verdict was not clean: \(result.verdict.message)")

        let ffmpeg = try FFTools.ffmpegURL()
        let decode = try await ProcessRunner.run(
            ffmpeg, ["-v", "error", "-xerror", "-i", dest.path, "-f", "null", "-"])
        #expect(decode.status == 0,
                "repaired file failed -xerror decode: \(String(data: decode.stderr, encoding: .utf8) ?? "")")

        let outDuration = try #require(await MediaProbe.probe(url: dest).duration)
        #expect(outDuration <= duration + 1.0,
                "output (\(outDuration) s) is longer than the source (\(duration) s) — the tail was filled, not trimmed")

        #expect(try Self.fileSize(source) == sourceSizeBefore)
    }

    @Test(.enabled(if: Fixture.available,
                   "truncated-ending capture absent — skipping (see ADR-0023)"))
    func verifyOutputProbesADurationWhenTheCallerHasNone() async throws {
        let source = try await Fixture.ensure()
        let progress = Progress()
        let verdict = await ClipDoctorEngine.verifyOutput(
            source, clipName: source.lastPathComponent, expectedDuration: nil
        ) { f in progress.record(f) }
        #expect(verdict.outcome != .inconclusive, "re-scan failed: \(verdict.message)")
        #expect(progress.maxSeen > 0, "no scan progress was reported — the duration fallback didn't fire")
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        func record(_ f: Double) { lock.lock(); value = max(value, f); lock.unlock() }
        var maxSeen: Double { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func fileSize(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }
}
