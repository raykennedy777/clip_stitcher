import Testing
import Foundation
@testable import ClipStitcher

/// The regression net for the output audio gate (issue #112): the export must refuse a file
/// whose rebuilt audio disagrees with the plan, and must go on accepting every file that
/// agrees with it.
///
/// The two halves are driven differently on purpose. **Rejection** is measured against a real
/// broken file — one built here with the pre-#111 length force, whose timeline collapses onto
/// a single timestamp exactly as the reported render's did — because the fixed engine can no
/// longer produce one, and a gate proven only against hand-written numbers isn't proven
/// against ffprobe. **Acceptance** is driven through the real `ExportEngine.export`, on all
/// three formats and in all three containers, because the risk a gate carries is not that it
/// misses a defect but that it rejects correct output (#19 is this project's precedent).
///
/// Owns no copyrighted bytes (ADR-0023): every source is synthesised with ffmpeg's `lavfi`
/// into a temp dir. The claim these synthetic sources can't make — that a *real* broadcast
/// capture with irregular timestamps still passes — was measured in the shell instead, on the
/// real MPEG-2 capture and on a 4.5 h HEVC capture, and those measurements are pinned as
/// facts in `OutputAudioGateTests`. Skips without asserting when ffmpeg isn't reachable, like
/// the sibling integration suites; run it alone with
/// `-only-testing:ClipStitcherTests/OutputAudioGateIntegrationTests`.
@Suite("Output audio gate (integration)", .serialized)
struct OutputAudioGateIntegrationTests {

    /// 25 fps, so a frame is exactly 0.04 s and a clip's kept duration is frames ÷ 25.
    private static let fps = 25.0

    // MARK: - Fixtures

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-audiogate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A source with a tone all the way through, 48 kHz stereo (the rebuilt track's rate and
    /// layout follow the source's, ADR-0014). `audioSeconds` shorter than the video is the
    /// issue-#111 trigger — a clip window past the audio end decodes to nothing.
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

    /// A file whose audio timeline is **collapsed**, built with the pre-#111 length force
    /// (`atrim=end_sample=N,apad=whole_len=N`) over a source whose audio ends before its
    /// video: the middle leg decodes to zero frames, and the padding then writes its samples
    /// without advancing timestamps. Measured on the file this produces: 235 of 330 MKV
    /// packets stamped 1.984 s of a planned 7 s.
    ///
    /// Not a hand-forged defect — it is the exact graph this engine shipped, so what the gate
    /// is proven against is the real failure, not an imitation of it.
    private static func makeCollapsedFile(_ source: URL, in dir: URL, ext: String,
                                          audioCodec: String) async throws -> URL? {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return nil }
        let url = dir.appendingPathComponent("collapsed.\(ext)")
        // Legs: 0–2 s (tone), 7–10 s (past the audio end), 1–3 s (tone) → 7 s planned.
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

    // MARK: - Production-shaped plumbing

    /// One clip over a probed source, built the way an import does, with its in/out points
    /// set — the planner then derives the kept window and duration from the frame index.
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

    /// Runs the real `ExportEngine.export` over planned items, resolving codec and output
    /// tracks exactly as `ProjectDocument.export` does (no target clip: every clip
    /// smart-renders against itself, so the video path is out of the way).
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

    // MARK: - The gate refuses a broken file

    /// The reported failure, in every container: the gate must reject it and leave nothing at
    /// the destination.
    ///
    /// The containers disagree about *which* check catches it, which is why both exist. MKV
    /// and TS show the duplicate timestamps outright, so the timeline-advance check names
    /// where the track froze. **MP4 masks them entirely** — its muxer bumps duplicates apart,
    /// so it has no stall at all and only the extent (2.016 s of a planned 7 s) gives it away.
    @Test(arguments: [("mkv", "aac"), ("mp4", "aac"), ("ts", "mp2")])
    func aCollapsedTrackIsRefusedAndTheFileIsDiscarded(ext: String, audioCodec: String) async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: "shortaudio",
                                                     codec: "libx264", audioSeconds: 4),
              let collapsed = try await Self.makeCollapsedFile(source, in: dir, ext: ext,
                                                              audioCodec: audioCodec)
        else { return }

        // The measurement itself, before the verdict: this really is the defect.
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

    /// The message has to say which track and where, so a caller reading stderr knows what
    /// failed rather than only that something did.
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

    /// A file that is fine in itself but shorter than the span it was measured against fails
    /// too — the extent half of the gate, and the shape `.separate` mode depends on: each
    /// file is checked against **its own** clip's kept duration, so a file holding clip 2's
    /// audio can't pass by matching the whole join's span.
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

        // Its own 2 s span passes; the 7 s span of a whole join does not.
        try await ExportEngine.verifyWrittenAudio(file, expectedTracks: 1, expectedExtent: 2.0)
        await #expect(throws: ExportError.self) {
            try await ExportEngine.verifyWrittenAudio(file, expectedTracks: 1, expectedExtent: 7.0)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - The gate passes correct output

    /// A clean multi-clip export on all three formats, in all three containers, must come out
    /// the other side of the gate — the export call itself throwing is the failure. Three
    /// clips joined, so every seam the audio rebuild makes is inside the file being verified.
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
        // And the gate agrees when asked directly with the plan's own span (50+75+50 frames).
        try await ExportEngine.verifyWrittenAudio(output, expectedTracks: 1,
                                                  expectedExtent: 175.0 / Self.fps)
    }

    /// Separate mode verifies each written file, so a clean two-clip run must produce both
    /// files and pass.
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

    /// A clip whose window decodes to **no** audio at all is now silence of exactly its kept
    /// duration (ADR-0028) — a correct export, and one the gate must let through rather than
    /// reading the standing-in silence as a fault.
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

    /// A **video-only** export has no rebuilt audio to check, so the gate must not run at all
    /// — asked to verify one track it would refuse the file outright, which is exactly what
    /// this asserts didn't happen. An **audio-only** export is still checked.
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

        // Audio-only: an elementary audio stream, which the gate reads the same way.
        let audioOnly = dir.appendingPathComponent("audioonly.m4a")
        try await Self.export(clips: [a, b], source: source,
                              settings: Self.settings(.connect, .mkv, .audioOnly), to: audioOnly)
        #expect(FileManager.default.fileExists(atPath: audioOnly.path))
        try await ExportEngine.verifyWrittenAudio(audioOnly, expectedTracks: 1,
                                                  expectedExtent: 150.0 / Self.fps)
    }

    /// Two output tracks, both correct: the gate reads each track separately, so a
    /// multi-track export must pass on all of them (and, per the unit suite, name the one
    /// that fails when one does).
    ///
    /// Run in every container because the gate also refuses a file carrying **fewer** tracks
    /// than the mux wrote, which only holds if each written track really does report its own
    /// packets exactly once — a TS program's streams are double-counted in `-show_streams`,
    /// so that is worth measuring rather than assuming.
    @Test(arguments: [Container.mkv, .mp4, .ts])
    func aMultiTrackExportPassesOnEveryTrack(container: Container) async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return }
        // A two-audio-stream source, so the resolver gives the output two tracks.
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
        // A clip's default audio selection is all of its own streams in container order
        // (`Clip.resolvedAudioSelections`), so both streams become output tracks unasked.
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
