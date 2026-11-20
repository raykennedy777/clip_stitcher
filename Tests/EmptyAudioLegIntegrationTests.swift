import Testing
import Foundation
@testable import ClipStitcher

@Suite("Empty audio leg (integration)", .serialized)
struct EmptyAudioLegIntegrationTests {
    private static let fps = 25.0
    private static let rate = 48000.0

    private static func makeSource(in dir: URL, name: String, codec: String,
                                   audioSeconds: Double, videoSeconds: Double = 12) async throws -> URL? {
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

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-emptyaudioleg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func audioPacketTimes(_ file: URL, scratch: URL) async throws -> [Double] {
        let ffprobe = try FFTools.ffprobeURL()
        let dump = scratch.appendingPathComponent("packets-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: dump) }
        let out = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "packet=pts_time", "-of", "csv=p=0", file.path], stdoutTo: dump)
        #expect(out.status == 0)
        return (try String(contentsOf: dump, encoding: .utf8))
            .split(separator: "\n")
            .compactMap { Double($0.split(separator: ",")[0]) }
    }

    private func expectStrictlyIncreasing(_ pts: [Double], _ label: String) {
        #expect(pts.count > 1, "\(label): only \(pts.count) audio packets")
        let repeats = zip(pts.dropFirst(), pts).filter { $0 <= $1 }
        #expect(repeats.isEmpty, "\(label): \(repeats.count) of \(pts.count) audio packets do not advance")
    }

    private func decodedSamples(_ file: URL, scratch: URL) async throws -> Int {
        let ffmpeg = try FFTools.ffmpegURL()
        let pcm = scratch.appendingPathComponent("decoded-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: pcm) }
        let result = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-i", file.path, "-map", "0:a:0",
            "-f", "s16le", "-c:a", "pcm_s16le", "-y", pcm.path])
        #expect(result.status == 0)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: pcm.path)[.size]) as? Int ?? 0
        return bytes / 4
    }

    private func containerDuration(_ file: URL) async throws -> Double? {
        let ffprobe = try FFTools.ffprobeURL()
        let out = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file.path])
        return Double((String(data: out.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func meanVolume(_ file: URL, start: Double, duration: Double) async throws -> Double? {
        let ffmpeg = try FFTools.ffmpegURL()
        let result = try await ProcessRunner.run(ffmpeg, [
            "-ss", String(start), "-t", String(duration), "-i", file.path,
            "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-"])
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        guard let line = stderr.split(separator: "\n").first(where: { $0.contains("mean_volume:") }),
              let value = line.split(separator: " ").compactMap({ Double($0) }).first else { return nil }
        return value
    }

    private static func clip(source: URL, name: String, inFrame: Int, outFrame: Int) async throws -> (Clip, FrameIndex, Double)? {
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

    private static func settings(_ mode: OutputMode, _ container: Container) -> OutputSettings {
        var s = OutputSettings()
        s.mode = mode
        s.container = container
        return s
    }

    @Test(arguments: [Container.mkv, .mp4, .ts])
    func anEmptyLegBecomesSilenceOfItsClipsLengthAndTheTimelineKeepsAdvancing(container: Container) async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: "shortaudio",
                                                     codec: "libx264", audioSeconds: 4) else { return }
        guard let a = try await Self.clip(source: source, name: "A", inFrame: 0, outFrame: 49),
              let b = try await Self.clip(source: source, name: "B", inFrame: 175, outFrame: 249),
              let c = try await Self.clip(source: source, name: "C", inFrame: 25, outFrame: 74)
        else { return }

        let output = dir.appendingPathComponent("joined.\(container.fileExtension)")
        try await Self.export(clips: [a, b, c], source: source,
                              settings: Self.settings(.connect, container), to: output)

        let span = (50.0 + 75.0 + 50.0) / Self.fps
        let audioFrame = 1024 / Self.rate

        let pts = try await audioPacketTimes(output, scratch: dir)
        expectStrictlyIncreasing(pts, "empty middle leg (\(container.fileExtension))")

        let first = try #require(pts.first)
        let last = try #require(pts.last)
        #expect(abs((last - first) - (span - audioFrame)) <= 2 * audioFrame,
                "\(container.fileExtension): audio spans \(last - first) s, planned \(span) s")
        let declared = try #require(try await containerDuration(output))
        #expect(abs(declared - span) <= 1 / Self.fps,
                "\(container.fileExtension): declared \(declared) s, planned \(span) s")
        let samples = try await decodedSamples(output, scratch: dir)
        #expect(abs(Double(samples) - span * Self.rate) <= 2 * 1152,
                "\(container.fileExtension): \(samples) samples decoded, planned \(Int(span * Self.rate))")

        let firstClip = try #require(try await meanVolume(output, start: 0.2, duration: 1.5))
        let emptySpan = try #require(try await meanVolume(output, start: 2.3, duration: 2.6))
        let afterEmpty = try #require(try await meanVolume(output, start: 5.1, duration: 1.8))
        #expect(firstClip > -40, "first clip should carry the tone, measured \(firstClip) dB")
        #expect(emptySpan < -80, "the empty leg's span should be silence, measured \(emptySpan) dB")
        #expect(afterEmpty > -40, "the clip after the empty leg should carry the tone, measured \(afterEmpty) dB")
    }

    @Test func inSeparateModeAnEmptyLegStillFillsItsOwnFile() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: "shortaudio",
                                                     codec: "libx264", audioSeconds: 4) else { return }
        guard let a = try await Self.clip(source: source, name: "A", inFrame: 0, outFrame: 49),
              let b = try await Self.clip(source: source, name: "B", inFrame: 175, outFrame: 249)
        else { return }

        let folder = dir.appendingPathComponent("separate", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await Self.export(clips: [a, b], source: source,
                              settings: Self.settings(.separate, .mkv), to: folder)

        let empty = folder.appendingPathComponent("02 B.mkv")
        #expect(FileManager.default.fileExists(atPath: empty.path))
        let span = 75.0 / Self.fps
        let audioFrame = 1024 / Self.rate
        let pts = try await audioPacketTimes(empty, scratch: dir)
        expectStrictlyIncreasing(pts, "separate empty leg")
        let first = try #require(pts.first)
        let last = try #require(pts.last)
        #expect(abs((last - first) - (span - audioFrame)) <= 2 * audioFrame,
                "audio spans \(last - first) s, planned \(span) s")
        let samples = try await decodedSamples(empty, scratch: dir)
        #expect(abs(Double(samples) - span * Self.rate) <= 2 * 1024,
                "\(samples) samples decoded, planned \(Int(span * Self.rate))")
        let level = try await meanVolume(empty, start: 0.2, duration: 2.5)
        #expect((level ?? 0) < -80, "the whole file should be silence, measured \(level ?? 0) dB")
    }

    @Test(arguments: [("mpeg2video", "mpeg2"), ("libx264", "h264"), ("libx265", "hevc")])
    func healthyLegsKeepTheirExactLengthAndTimeline(codec: String, name: String) async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: name, codec: codec,
                                                     audioSeconds: 6, videoSeconds: 6) else { return }
        guard let a = try await Self.clip(source: source, name: "A", inFrame: 0, outFrame: 49),
              let b = try await Self.clip(source: source, name: "B", inFrame: 60, outFrame: 109)
        else { return }

        let output = dir.appendingPathComponent("joined-\(name).mkv")
        try await Self.export(clips: [a, b], source: source,
                              settings: Self.settings(.connect, .mkv), to: output)

        let span = 100.0 / Self.fps
        let pts = try await audioPacketTimes(output, scratch: dir)
        expectStrictlyIncreasing(pts, "healthy \(name)")
        let samples = try await decodedSamples(output, scratch: dir)
        #expect(abs(Double(samples) - span * Self.rate) <= 2 * 1024,
                "\(name): \(samples) samples decoded, planned \(Int(span * Self.rate))")
        let level = try await meanVolume(output, start: 0.2, duration: 3.5)
        #expect((level ?? -100) > -40, "\(name): the tone should be present throughout, measured \(level ?? -100) dB")
    }
}
