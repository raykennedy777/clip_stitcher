import Testing
import Foundation
@testable import ClipStitcher

struct ClipDoctorRepairTests {
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

    @Test func repairWithoutVideoIsAnInvalidPlan() async {
        var clip = videoClip()
        clip.video = nil
        await #expect(throws: ExportError.self) {
            try await ClipDoctorEngine.repair(
                source: URL(fileURLWithPath: "/x/in.ts"), clip: clip,
                index: dummyIndex, containerStart: 0)
        }
    }

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

    @Test func aDestinationEqualToTheSourceIsRefused() async {
        let source = URL(fileURLWithPath: "/x/in.ts")
        do {
            _ = try await ClipDoctorEngine.repair(
                source: source, clip: videoClip(), index: dummyIndex,
                containerStart: 0, destination: source)
            Issue.record("expected destinationIsSource")
        } catch ClipDoctorEngine.DoctorError.destinationIsSource {
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func aSymlinkedDestinationOntoTheSourceIsRefused() async throws {
        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent("cs77-src-\(UUID().uuidString).ts")
        fm.createFile(atPath: source.path, contents: Data("original".utf8))
        let link = fm.temporaryDirectory.appendingPathComponent("cs77-link-\(UUID().uuidString).ts")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        defer { try? fm.removeItem(at: source); try? fm.removeItem(at: link) }

        do {
            _ = try await ClipDoctorEngine.repair(
                source: source, clip: videoClip(), index: dummyIndex,
                containerStart: 0, destination: link)
            Issue.record("expected destinationIsSource")
        } catch ClipDoctorEngine.DoctorError.destinationIsSource {
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    }

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
        #expect(try String(contentsOf: dest, encoding: .utf8) == "keep me")
    }

    @Test func progressiveRepairProducesACleanVerifiedSiblingWithoutTouchingTheSource() async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cs63-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

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
        clip.damageZones = [DamageZone(start: 1.5, end: 2.0, affectsVideo: true)]

        let sourceSizeBefore = try Self.fileSize(source)
        let dest = work.appendingPathComponent("source_repaired.ts")

        let result = try await ClipDoctorEngine.repair(
            source: source, clip: clip, index: scan.index, containerStart: containerStart,
            destination: dest, overwrite: true)

        #expect(result.verdict.clean, "verdict was not clean: \(result.verdict.message)")
        #expect(result.repairedZoneCount == 1)

        #expect(fm.fileExists(atPath: dest.path))
        let outProbe = try await MediaProbe.probe(url: dest)
        #expect(outProbe.video?.codec == "h264")
        #expect(outProbe.audioTracks.contains { $0.codec == "mp2" })
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
