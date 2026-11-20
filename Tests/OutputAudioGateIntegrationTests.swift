import Testing
import Foundation
@testable import ClipStitcher

@Suite("Output audio gate (integration)", .serialized)
struct OutputAudioGateIntegrationTests {
    private static let fps = 25.0

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-audiogate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeSource(in dir: URL, name: String, codec: String,
                                   audioSeconds: Double = 12,
                                   videoSeconds: Double = 12) async throws -> URL? {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return nil }
        let url = dir.appendingPathComponent("\(name).mkv")
        let result = try await ProcessRunner.run(ffmpeg, [
            "-v", "error",
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=\(videoSeconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(audioSeconds)",
            "-map", "0:v", "-map", "1:a",
            "-c:v", codec, "-g", "12", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-ac", "2", "-y", url.path])
        guard result.status == 0 else { return nil }
        return url
    }

    private static func makeCollapsedFile(_ source: URL, in dir: URL, ext: String,
                                          audioCodec: String) async throws -> URL? {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return nil }
        let url = dir.appendingPathComponent("collapsed.\(ext)")
        let samples = [96_000, 144_000, 96_000]
        var chains: [String] = []
        for (i, n) in samples.enumerated() {
            chains.append("[\(i):a:0]aresample=48000:async=1:first_pts=0"
                          + ",aformat=channel_layouts=stereo"
                          + ",atrim=end_sample=\(n),apad=whole_len=\(n)[c\(i)]")
        }
        chains.append("[c0][c1][c2]concat=n=3:v=0:a=1[a0]")
        var args = ["-y", "-v", "error"]
        for (start, duration) in [(0.0, 2.0), (7.0, 3.0), (1.0, 2.0)] {
            args += ["-ss", String(start), "-t", String(duration), "-i", source.path]
        }
        args += ["-filter_complex", chains.joined(separator: ";"),
                 "-map", "[a0]", "-c:a", audioCodec, "-b:a", "192k", url.path]
        let result = try await ProcessRunner.run(ffmpeg, args)
        guard result.status == 0 else { return nil }
        return url
    }

    private static func clip(source: URL, name: String, inFrame: Int,
                             outFrame: Int) async throws -> (Clip, FrameIndex, Double)? {
        let probe = try await MediaProbe.probe(url: source)
        guard let video = probe.video else { return nil }
        let scan = try await FrameIndexer.scanAllStreams(url: source)
        let containerStart = await MediaProbe.containerStartTime(url: source)
        var clip = Clip(bookmark: Data(), displayName: name, video: video)
        clip.audioTracks = probe.audioTracks
        clip.duration = probe.duration
        clip.frameCount = scan.index.count
        clip.inPoint = inFrame
        clip.outPoint = outFrame
        return (clip, scan.index, containerStart)
    }

    private static func export(clips: [(Clip, FrameIndex, Double)], source: URL,
                              settings: OutputSettings, to destination: URL) async throws {
        var items: [ExportItem] = []
        for (clip, index, containerStart) in clips {
            items.append(try ExportPlanner.planItem(
                for: ExportPlanner.ClipInput(
                    clip: clip, url: source, index: index, containerStart: containerStart,
                    audioSources: AudioSourceResolver.resolveSources(for: clip, missingExternal: .throwError),
                    audioMixFilters: AudioSourceResolver.resolveMixFilters(for: clip)),
                target: nil, settings: settings))
        }
        let audio = AudioCodecPolicy.resolveAudioCodec(targetCodec: nil, container: settings.container)
        let tracks = AudioSourceResolver.resolveOutputTracks(target: nil, clips: clips.map(\.0))
        try await ExportEngine.export(items: items, settings: settings,
                                      audioCodec: audio.encoder, tracks: tracks, to: destination)
    }

    private static func settings(_ mode: OutputMode, _ container: Container,
                                 _ type: OutputType = .videoAndAudio) -> OutputSettings {
        var s = OutputSettings()
        s.mode = mode
        s.container = container
        s.type = type
        return s
    }

    @Test(arguments: [("mkv", "aac"), ("mp4", "aac"), ("ts", "mp2")])
    func aCollapsedTrackIsRefusedAndTheFileIsDiscarded(ext: String, audioCodec: String) async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: "shortaudio",
                                                     codec: "libx264", audioSeconds: 4),
              let collapsed = try await Self.makeCollapsedFile(source, in: dir, ext: ext,
                                                              audioCodec: audioCodec)
        else { return }

        let timelines = try await MediaProbe.audioTimelines(url: collapsed)
        #expect(timelines.count == 1)
        let measured = try #require(timelines.first)
        let interval = try #require(measured.packetInterval)
        #expect(try #require(measured.span) + interval < 3.0,
                "\(ext): the collapsed track should measure ~2 s, not \(measured.span ?? -1) s")

        await #expect(throws: ExportError.self) {
            try await ExportEngine.verifyWrittenAudio(collapsed, expectedTracks: 1,
                                                      expectedExtent: 7.0)
        }
        #expect(!FileManager.default.fileExists(atPath: collapsed.path),
                "\(ext): a file that failed verification must not be left at the destination")
    }

    @Test func theRefusalNamesTheTrackAndWhatItMeasured() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: "shortaudio",
                                                     codec: "libx264", audioSeconds: 4),
              let collapsed = try await Self.makeCollapsedFile(source, in: dir, ext: "mkv",
                                                               audioCodec: "aac")
        else { return }
        var message = ""
        do {
            try await ExportEngine.verifyWrittenAudio(collapsed, expectedTracks: 1,
                                                      expectedExtent: 7.0)
        } catch let error as ExportError {
            message = error.errorDescription ?? ""
        }
        #expect(message.contains("track 1"), "message was: \(message)")
        #expect(message.contains("1.984") || message.contains("stops advancing"),
                "message was: \(message)")
    }

    @Test func aFileShorterThanItsPlannedSpanIsRefused() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: "tone", codec: "libx264"),
              let a = try await Self.clip(source: source, name: "A", inFrame: 0, outFrame: 49)
        else { return }
        let folder = dir.appendingPathComponent("separate", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await Self.export(clips: [a], source: source,
                              settings: Self.settings(.separate, .mkv), to: folder)
        let file = folder.appendingPathComponent("01 A.mkv")
        #expect(FileManager.default.fileExists(atPath: file.path))

        try await ExportEngine.verifyWrittenAudio(file, expectedTracks: 1, expectedExtent: 2.0)
        await #expect(throws: ExportError.self) {
            try await ExportEngine.verifyWrittenAudio(file, expectedTracks: 1, expectedExtent: 7.0)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: ["mpeg2video", "libx264", "libx265"], [Container.mkv, .mp4, .ts])
    func aCleanConnectExportStillPasses(codec: String, container: Container) async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: "clean", codec: codec),
              let a = try await Self.clip(source: source, name: "A", inFrame: 0, outFrame: 49),
              let b = try await Self.clip(source: source, name: "B", inFrame: 175, outFrame: 249),
              let c = try await Self.clip(source: source, name: "C", inFrame: 25, outFrame: 74)
        else { return }
        let output = dir.appendingPathComponent("joined.\(container.fileExtension)")
        try await Self.export(clips: [a, b, c], source: source,
                              settings: Self.settings(.connect, container), to: output)
        #expect(FileManager.default.fileExists(atPath: output.path))
        try await ExportEngine.verifyWrittenAudio(output, expectedTracks: 1,
                                                  expectedExtent: 175.0 / Self.fps)
    }

    @Test func aCleanSeparateExportStillPasses() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: "clean", codec: "libx264"),
              let a = try await Self.clip(source: source, name: "A", inFrame: 0, outFrame: 49),
              let b = try await Self.clip(source: source, name: "B", inFrame: 100, outFrame: 199)
        else { return }
        let folder = dir.appendingPathComponent("separate", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await Self.export(clips: [a, b], source: source,
                              settings: Self.settings(.separate, .mkv), to: folder)
        for name in ["01 A.mkv", "02 B.mkv"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        }
    }

    @Test func theSilenceBackedEmptyLegPasses() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: "shortaudio",
                                                     codec: "libx264", audioSeconds: 4),
              let a = try await Self.clip(source: source, name: "A", inFrame: 0, outFrame: 49),
              let b = try await Self.clip(source: source, name: "B", inFrame: 175, outFrame: 249),
              let c = try await Self.clip(source: source, name: "C", inFrame: 25, outFrame: 74)
        else { return }
        let output = dir.appendingPathComponent("joined.mkv")
        try await Self.export(clips: [a, b, c], source: source,
                              settings: Self.settings(.connect, .mkv), to: output)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func videoOnlySkipsTheGateAndAudioOnlyIsChecked() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: "clean", codec: "libx264"),
              let a = try await Self.clip(source: source, name: "A", inFrame: 0, outFrame: 49),
              let b = try await Self.clip(source: source, name: "B", inFrame: 100, outFrame: 199)
        else { return }

        let videoOnly = dir.appendingPathComponent("videoonly.mkv")
        try await Self.export(clips: [a, b], source: source,
                              settings: Self.settings(.connect, .mkv, .videoOnly), to: videoOnly)
        #expect(FileManager.default.fileExists(atPath: videoOnly.path))
        let tracks = try await MediaProbe.audioTimelines(url: videoOnly)
        #expect(tracks.isEmpty, "a video-only export has no audio for the gate to check")

        let audioOnly = dir.appendingPathComponent("audioonly.m4a")
        try await Self.export(clips: [a, b], source: source,
                              settings: Self.settings(.connect, .mkv, .audioOnly), to: audioOnly)
        #expect(FileManager.default.fileExists(atPath: audioOnly.path))
        try await ExportEngine.verifyWrittenAudio(audioOnly, expectedTracks: 1,
                                                  expectedExtent: 150.0 / Self.fps)
    }

    @Test(arguments: [Container.mkv, .mp4, .ts])
    func aMultiTrackExportPassesOnEveryTrack(container: Container) async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        let source = dir.appendingPathComponent("twotrack.mkv")
        let made = try await ProcessRunner.run(ffmpeg, [
            "-v", "error",
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=12",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=12",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=12",
            "-map", "0:v", "-map", "1:a", "-map", "2:a",
            "-c:v", "libx264", "-g", "12", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-ac", "2", "-y", source.path])
        guard made.status == 0 else { return }
        guard let a = try await Self.clip(source: source, name: "A", inFrame: 0, outFrame: 49),
              let b = try await Self.clip(source: source, name: "B", inFrame: 100, outFrame: 199)
        else { return }

        let output = dir.appendingPathComponent("twotrack-out.\(container.fileExtension)")
        try await Self.export(clips: [a, b], source: source,
                              settings: Self.settings(.connect, container), to: output)
        let timelines = try await MediaProbe.audioTimelines(url: output)
        #expect(timelines.count == 2,
                "\(container.fileExtension): each written track must report its own packets exactly once, measured \(timelines.count)")
        try await ExportEngine.verifyWrittenAudio(output, expectedTracks: 2,
                                                  expectedExtent: 150.0 / Self.fps)
    }
}
