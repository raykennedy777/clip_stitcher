import Testing
import Foundation
@testable import ClipStitcher

/// The regression net for ADR-0028 (issue #111): an audio leg whose window decodes to
/// **zero frames** must still contribute exactly its clip's kept duration.
///
/// Pre-fix, the length force was `atrim=end_sample=N,apad=whole_len=N`. On an empty leg the
/// padding still wrote its samples but stopped advancing timestamps, so every audio packet
/// from that join onward carried **one identical pts** (measured in the shell: 281 of 376
/// packets stamped 1.984 s of a planned 8 s). Nothing else showed it — all samples were
/// present, the video stayed frame-exact, ffmpeg exited 0 with empty stderr — which is why
/// the assertions here are on the audio *timeline*: packet monotonicity, where the last
/// packet sits, and where the sound actually lands, never on sample count alone.
///
/// Owns no copyrighted bytes (ADR-0023): every source is synthesised with ffmpeg's `lavfi`
/// into a temp dir. The trigger — a source whose audio stream ends long before its video —
/// is directly constructible that way, so a clip window past the audio end decodes to
/// nothing exactly as a failed decode does. Skips without asserting when ffmpeg isn't
/// reachable, like the sibling integration suites; run it alone with
/// `-only-testing:ClipStitcherTests/EmptyAudioLegIntegrationTests`.
@Suite("Empty audio leg (integration)", .serialized)
struct EmptyAudioLegIntegrationTests {

    /// 25 fps, so a frame is exactly 0.04 s and a clip's kept duration is frames ÷ 25.
    private static let fps = 25.0
    private static let rate = 48000.0

    /// A source whose **audio ends at 4 s while its video runs to 12 s**: any clip window
    /// past 4 s decodes to zero audio frames. `codec` picks the video encoder so the same
    /// shape is provable on MPEG-2, H.264 and HEVC. The tone is pinned to 48 kHz stereo —
    /// `sine` defaults to 44.1 kHz mono, and the rebuilt track's rate and layout follow the
    /// source track (ADR-0014), so the planned sample counts below would be measured
    /// against the wrong rate.
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

    // MARK: - Measurements

    /// Every audio packet's pts, in muxed order. Dumped to a **file** (`stdoutTo`), not a
    /// pipe: a per-packet dump is unbounded, and `ProcessRunner` without a sink drains
    /// stdout only at termination, so a long source would deadlock against the ~64 KB pipe
    /// buffer.
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

    /// The defect stated as the invariant it breaks: audio packet timestamps strictly
    /// increase. A collapsed leg leaves hundreds of packets sharing one pts.
    private func expectStrictlyIncreasing(_ pts: [Double], _ label: String) {
        #expect(pts.count > 1, "\(label): only \(pts.count) audio packets")
        let repeats = zip(pts.dropFirst(), pts).filter { $0 <= $1 }
        #expect(repeats.isEmpty, "\(label): \(repeats.count) of \(pts.count) audio packets do not advance")
    }

    /// Decoded sample count per channel — the audio's real extent. The container's declared
    /// duration is *not* a substitute: on the collapsed render it read 2.03 s of a file
    /// holding 8 s of samples.
    private func decodedSamples(_ file: URL, scratch: URL) async throws -> Int {
        let ffmpeg = try FFTools.ffmpegURL()
        // To a file, never stdout: `ProcessRunner` without a sink drains the pipe only at
        // termination, and megabytes of PCM would deadlock against the ~64 KB pipe buffer.
        let pcm = scratch.appendingPathComponent("decoded-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: pcm) }
        let result = try await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-i", file.path, "-map", "0:a:0",
            "-f", "s16le", "-c:a", "pcm_s16le", "-y", pcm.path])
        #expect(result.status == 0)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: pcm.path)[.size]) as? Int ?? 0
        return bytes / 4               // s16, 2 channels
    }

    private func containerDuration(_ file: URL) async throws -> Double? {
        let ffprobe = try FFTools.ffprobeURL()
        let out = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file.path])
        return Double((String(data: out.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `volumedetect`'s mean level over a window of the output's audio — how a span of
    /// standing-in silence is told from a span that carries the source's tone. No `-v error`:
    /// the filter reports its statistics at *info* level, and quietening ffmpeg drops them.
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

    // MARK: - Production-shaped plumbing

    /// One clip over a probed source, built the way an import does, with its in/out points
    /// set — the planner then derives the kept window and duration from the frame index.
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

    private static func settings(_ mode: OutputMode, _ container: Container) -> OutputSettings {
        var s = OutputSettings()
        s.mode = mode
        s.container = container
        return s
    }

    // MARK: - The defect

    /// The reported shape, in connect mode: three clips, the middle one's window entirely
    /// past the source's audio end. Its leg decodes to nothing, and pre-fix that stamped
    /// every packet after the first join with one pts — the whole tail of the track.
    ///
    /// Run in all three containers, because they disagree about how the defect *looks*:
    /// MKV shows the duplicate timestamps outright, TS shows some of them, and **MP4 masks
    /// them entirely** (its muxer bumps duplicates apart) — there only the extent gives it
    /// away. Judging any one container alone, or container duration alone, misses it.
    @Test(arguments: [Container.mkv, .mp4, .ts])
    func anEmptyLegBecomesSilenceOfItsClipsLengthAndTheTimelineKeepsAdvancing(container: Container) async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let source = try await Self.makeSource(in: dir, name: "shortaudio",
                                                     codec: "libx264", audioSeconds: 4) else { return }
        // 0–2 s (tone), 7–10 s (past the audio end — the empty leg), 1–3 s (tone).
        guard let a = try await Self.clip(source: source, name: "A", inFrame: 0, outFrame: 49),
              let b = try await Self.clip(source: source, name: "B", inFrame: 175, outFrame: 249),
              let c = try await Self.clip(source: source, name: "C", inFrame: 25, outFrame: 74)
        else { return }

        let output = dir.appendingPathComponent("joined.\(container.fileExtension)")
        try await Self.export(clips: [a, b, c], source: source,
                              settings: Self.settings(.connect, container), to: output)

        let span = (50.0 + 75.0 + 50.0) / Self.fps       // 7 s of planned audio
        let audioFrame = 1024 / Self.rate                // one encoded audio frame

        // 1. The timeline advances across every join.
        let pts = try await audioPacketTimes(output, scratch: dir)
        expectStrictlyIncreasing(pts, "empty middle leg (\(container.fileExtension))")

        // 2. The track really is as long as the plan. Measured first-to-last packet: TS
        //    timestamps carry a container base offset, so an absolute pts would be reading
        //    the muxer's origin, not the audio's extent. Two audio frames of slack, and
        //    both are accounted for: the last packet starts one frame before the end, and
        //    the encoder's priming frame sits *before* zero (a deliberate compensation, not
        //    a sync error — measured first pts −0.021 s here). Sample-exactness of the legs
        //    themselves is pinned upstream, on the filter graph (`ExportEngineTests`).
        let first = try #require(pts.first)
        let last = try #require(pts.last)
        #expect(abs((last - first) - (span - audioFrame)) <= 2 * audioFrame,
                "\(container.fileExtension): audio spans \(last - first) s, planned \(span) s")
        // The declared duration must agree too — this is what read 2.03 s of a planned 8 s
        // pre-fix. The tolerance is one video frame: TS rounds the last packet's slot away.
        let declared = try #require(try await containerDuration(output))
        #expect(abs(declared - span) <= 1 / Self.fps,
                "\(container.fileExtension): declared \(declared) s, planned \(span) s")
        // Sample count was *already right* on the broken render (the samples were written,
        // their timestamps weren't), so this is a completeness check, not the defect net.
        // The slack is the codec's frame granularity plus its priming: AAC's frame is 1024
        // samples, the mp2 the TS container takes is 1152, and neither divides the span.
        let samples = try await decodedSamples(output, scratch: dir)
        #expect(abs(Double(samples) - span * Self.rate) <= 2 * 1152,
                "\(container.fileExtension): \(samples) samples decoded, planned \(Int(span * Self.rate))")

        // 3. The empty leg's span is silence of its clip's length and the clip after it is
        //    not pulled earlier — probed right up to the boundary at 5 s: silence through
        //    4.9 s, tone from 5.1 s. `volumedetect`'s floor for digital silence is ≈ −91 dB.
        let firstClip = try #require(try await meanVolume(output, start: 0.2, duration: 1.5))
        let emptySpan = try #require(try await meanVolume(output, start: 2.3, duration: 2.6))
        let afterEmpty = try #require(try await meanVolume(output, start: 5.1, duration: 1.8))
        #expect(firstClip > -40, "first clip should carry the tone, measured \(firstClip) dB")
        #expect(emptySpan < -80, "the empty leg's span should be silence, measured \(emptySpan) dB")
        #expect(afterEmpty > -40, "the clip after the empty leg should carry the tone, measured \(afterEmpty) dB")
    }

    /// The same source in `.separate` mode, where the empty-audio clip is muxed on its own:
    /// its file must still hold its full kept duration of silence.
    ///
    /// This one is a no-regression assertion rather than a net for the defect: a separate
    /// file's chain holds a **single** leg, so it has no join to collapse at, and the old
    /// force already produced the right file here (verified by mutating the fix back — the
    /// connect test fails, this one passes). It pins the behaviour the fix must not change
    /// in the mode that was never broken.
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

        // `NN <clip name>.<ext>` in timeline order (issue #30).
        let empty = folder.appendingPathComponent("02 B.mkv")
        #expect(FileManager.default.fileExists(atPath: empty.path))
        let span = 75.0 / Self.fps                       // 3 s
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

    /// The other half of the fix: a **healthy** source's rebuild is unchanged. Asserted on
    /// all three formats (the standing rule) as the exact sample count the plan implies plus
    /// a monotonic timeline — the shell de-risk pinned the stronger property, that healthy
    /// legs are bit-identical to the pre-fix graph (decoded-PCM md5 on MPEG-2/H.264/HEVC in
    /// .mkv, .mp4 and .ts).
    @Test(arguments: [("mpeg2video", "mpeg2"), ("libx264", "h264"), ("libx265", "hevc")])
    func healthyLegsKeepTheirExactLengthAndTimeline(codec: String, name: String) async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Audio as long as the video: no leg is empty, so this is the no-regression case.
        guard let source = try await Self.makeSource(in: dir, name: name, codec: codec,
                                                     audioSeconds: 6, videoSeconds: 6) else { return }
        guard let a = try await Self.clip(source: source, name: "A", inFrame: 0, outFrame: 49),
              let b = try await Self.clip(source: source, name: "B", inFrame: 60, outFrame: 109)
        else { return }

        let output = dir.appendingPathComponent("joined-\(name).mkv")
        try await Self.export(clips: [a, b], source: source,
                              settings: Self.settings(.connect, .mkv), to: output)

        let span = 100.0 / Self.fps                      // 4 s
        let pts = try await audioPacketTimes(output, scratch: dir)
        expectStrictlyIncreasing(pts, "healthy \(name)")
        let samples = try await decodedSamples(output, scratch: dir)
        #expect(abs(Double(samples) - span * Self.rate) <= 2 * 1024,
                "\(name): \(samples) samples decoded, planned \(Int(span * Self.rate))")
        let level = try await meanVolume(output, start: 0.2, duration: 3.5)
        #expect((level ?? -100) > -40, "\(name): the tone should be present throughout, measured \(level ?? -100) dB")
    }
}
