import Testing
import Foundation
@testable import ClipStitcher

@Suite("Probe consolidation (integration)")
struct ProbeConsolidationIntegrationTests {
    private static func makeClip(codec: String = "mpeg2video") async throws -> URL? {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("synthetic.ts")
        let result = try await ProcessRunner.run(ffmpeg, [
            "-v", "error",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:v", codec, "-c:a", "mp2", "-y", url.path])
        guard result.status == 0 else { return nil }
        return url
    }

    @Test func probeSurfacesContainerStartInASingleLaunch() async throws {
        guard let url = try await Self.makeClip(codec: "libx264") else { return }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let probeCounter = ProcessRunner.LaunchCounter()
        var probe: MediaProbe.Result?
        try await ProcessRunner.$launchCounter.withValue(probeCounter) {
            probe = try await MediaProbe.probe(url: url)
        }
        #expect(probeCounter.count == 1)

        let dedicatedCounter = ProcessRunner.LaunchCounter()
        var dedicated = -1.0
        await ProcessRunner.$launchCounter.withValue(dedicatedCounter) {
            dedicated = await MediaProbe.containerStartTime(url: url)
        }
        #expect(dedicatedCounter.count == 1)
        #expect(probe?.containerStart == dedicated)
        #expect((probe?.containerStart ?? 0) > 0)
    }

    @Test func mpeg2PaysOneExtraLaunchToMeasureItsBitrate() async throws {
        guard let url = try await Self.makeClip() else { return }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let counter = ProcessRunner.LaunchCounter()
        var probe: MediaProbe.Result?
        try await ProcessRunner.$launchCounter.withValue(counter) {
            probe = try await MediaProbe.probe(url: url)
        }
        #expect(counter.count == 2)
        #expect(probe?.video?.codec == "mpeg2video")
        #expect((probe?.video?.bitrate ?? 0) > 0)
    }

    @MainActor
    @Test func repeatedContainerStartLookupsProbeOnlyOnce() async throws {
        guard let url = try await Self.makeClip() else { return }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let doc = ProjectDocument()
        let clip = Clip(bookmark: (try? url.bookmarkData()) ?? Data(),
                        displayName: url.lastPathComponent)
        doc.project.clips = [clip]

        let miss = ProcessRunner.LaunchCounter()
        var first = -1.0
        await ProcessRunner.$launchCounter.withValue(miss) {
            first = await doc.containerStart(for: clip)
        }
        #expect(miss.count == 1)

        let hit = ProcessRunner.LaunchCounter()
        var second = -1.0
        await ProcessRunner.$launchCounter.withValue(hit) {
            second = await doc.containerStart(for: clip)
        }
        #expect(hit.count == 0)
        #expect(first == second)
    }
}
