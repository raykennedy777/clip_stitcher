import Testing
import Foundation
@testable import ClipStitcher

/// Verifies the redundant-probe cuts (issue #85): `MediaProbe.probe` surfaces the container
/// start_time in a **single** ffprobe launch (so the import path no longer probes twice), and
/// the document's container-start cache means a repeated preview-style lookup probes **zero**
/// times.
///
/// Owns no copyrighted bytes (ADR-0023): it synthesises a tiny clip with ffmpeg's `testsrc`
/// into a temp dir on demand, and skips loudly (returns without asserting) when ffmpeg isn't
/// reachable. Its own suite so the fast unit run can `-skip-testing` it and it runs on demand
/// with `-only-testing:ClipStitcherTests/ProbeConsolidationIntegrationTests`.
@Suite("Probe consolidation (integration)")
struct ProbeConsolidationIntegrationTests {

    /// A synthetic MPEG-TS clip (no copyrighted media): 1 s of `testsrc` + a sine tone muxed to
    /// TS so it carries a non-zero container start_time — the value the consolidation surfaces.
    /// Returns `nil` (the test then skips) when ffmpeg isn't available on this machine.
    private static func makeClip() async throws -> URL? {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("synthetic.ts")
        let result = try await ProcessRunner.run(ffmpeg, [
            "-v", "error",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:v", "mpeg2video", "-c:a", "mp2", "-y", url.path])
        guard result.status == 0 else { return nil }
        return url
    }

    /// Item 1: one properties probe carries start_time, so the second dedicated probe import
    /// used to pay is gone. Counts subprocess launches via the task-local counter so parallel
    /// suites can't corrupt the tally.
    @Test func probeSurfacesContainerStartInASingleLaunch() async throws {
        guard let url = try await Self.makeClip() else { return }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let probeCounter = ProcessRunner.LaunchCounter()
        var probe: MediaProbe.Result?
        try await ProcessRunner.$launchCounter.withValue(probeCounter) {
            probe = try await MediaProbe.probe(url: url)
        }
        // The full `-show_streams -show_format` probe is a single process — and it already
        // carried start_time, so the import path reads it from here, not a second launch.
        #expect(probeCounter.count == 1)

        let dedicatedCounter = ProcessRunner.LaunchCounter()
        var dedicated = -1.0
        await ProcessRunner.$launchCounter.withValue(dedicatedCounter) {
            dedicated = await MediaProbe.containerStartTime(url: url)
        }
        // The old dedicated start_time probe is its own separate launch — the one import used
        // to pay on top of the properties probe, now saved — and it agrees with the folded value.
        #expect(dedicatedCounter.count == 1)
        #expect(probe?.containerStart == dedicated)
        #expect((probe?.containerStart ?? 0) > 0)   // TS carries a real non-zero start
    }

    /// Item 2: the document's container-start lookup (what the Output Preview now reads on every
    /// load) probes once on a miss and never again — a repeated preview load probes nothing.
    @MainActor
    @Test func repeatedContainerStartLookupsProbeOnlyOnce() async throws {
        guard let url = try await Self.makeClip() else { return }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let doc = ProjectDocument()
        let clip = Clip(bookmark: (try? url.bookmarkData()) ?? Data(),
                        displayName: url.lastPathComponent)
        doc.project.clips = [clip]

        // First lookup misses the cache and probes once.
        let miss = ProcessRunner.LaunchCounter()
        var first = -1.0
        await ProcessRunner.$launchCounter.withValue(miss) {
            first = await doc.containerStart(for: clip)
        }
        #expect(miss.count == 1)

        // Every later lookup — the preview's per-load read — hits the cache and probes nothing.
        let hit = ProcessRunner.LaunchCounter()
        var second = -1.0
        await ProcessRunner.$launchCounter.withValue(hit) {
            second = await doc.containerStart(for: clip)
        }
        #expect(hit.count == 0)
        #expect(first == second)
    }
}
