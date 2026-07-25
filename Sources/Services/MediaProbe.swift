import Foundation

/// Probes a media file with ffprobe and maps the result to our property types.
///
/// One interface over ffprobe: callers ask for facts — the stream/format properties,
/// the container start time, a video stream's timebase — and the ffprobe invocation
/// shapes and parsing quirks stay inside. Each probe splits into the invocation (the
/// exact, shell-validated argument array) and a pure parser unit-tested off canned
/// ffprobe output, including the known quirks: ffprobe's CSV writer emits a trailing
/// comma on MPEG-2 streams, and reports "N/A" for values a demuxer doesn't carry.
enum MediaProbe {
    struct Result: Sendable {
        var video: VideoProperties?
        /// The first audio stream — the legacy single-track field (kept filled so
        /// existing call sites and old saves keep working; ADR-0014).
        var audio: AudioProperties?
        /// Every audio stream, in container order.
        var audioTracks: [AudioProperties] = []
        var duration: Double?
        /// The container-level start_time in seconds — the ADR-0013 input `-ss` base. Read
        /// straight off the same `-show_format` JSON `probe` already fetches (issue #85), so
        /// the import path needs no second, dedicated ffprobe for it. 0 when the demuxer
        /// carries none ("N/A") — also the correct seek offset for such files.
        var containerStart: Double = 0
        /// The video stream's r_frame_rate, kept separately from
        /// `VideoProperties.frameRate` (avg-first) for the field-coding check
        /// (issue #46): on a PAFF capture avg_frame_rate is the *field* rate
        /// (ffprobe derives it from packet count) while r_frame_rate carries the
        /// codec's true display rate — the detector wants both candidates.
        var videoCodecFrameRate: String? = nil
    }

    static func probe(url: URL) async throws -> Result {
        let ffprobe = try FFTools.ffprobeURL()
        let output = try await ProcessRunner.run(ffprobe, [
            "-v", "quiet",
            "-print_format", "json",
            "-show_streams",
            "-show_format",
            url.path,
        ])
        guard output.status == 0 else {
            throw FFError.probeFailed(String(data: output.stderr, encoding: .utf8) ?? "exit \(output.status)")
        }
        var result = try parseProbe(json: output.stdout)
        // MPEG-PS generally carries no video-stream `bit_rate`, and MPEG-2 is the one family
        // whose re-encode has no CRF mode to fall back on — it targets the source's own rate
        // instead (issue #110). Measure it with a bounded packet sample, only when the
        // container didn't report it and only for that codec: every other source re-encodes
        // at a fixed CRF and never reads the number, so no import pays for a second probe.
        if result.video?.codec == "mpeg2video", result.video?.bitrate == nil {
            result.video?.bitrate = await sampledVideoBitrate(url: url)
        }
        return result
    }

    // MARK: - Sampled video bitrate (#110)

    /// How much of the video stream a bitrate sample reads. Bounded on purpose: a 4.8 h
    /// broadcast capture is tens of gigabytes and the number only has to be right to within
    /// a few percent — the ×1.25 headroom the re-encode target adds swamps the sampling
    /// error. Measured on the real MPEG-PS fixture: a 60 s sample read in 0.05 s and landed
    /// 5 % above the whole-file average (2.663 vs 2.531 Mbps).
    static let bitrateSampleSeconds = 60

    /// The video stream's average bitrate in bits/sec, measured by summing packet sizes over
    /// the first `bitrateSampleSeconds` of the stream (issue #110). The window is the file's
    /// head rather than the re-encoded span's neighbourhood — the probe runs at import, long
    /// before any cut exists — which is why the target adds headroom rather than matching the
    /// measurement exactly. nil when the probe fails or the window holds too few timed
    /// packets to measure a span; the caller then falls back to a fixed quantiser.
    /// The sample is a **per-packet** dump — thousands of entries, ~100 KB of JSON for a 60 s
    /// window — so it streams to a temp file like the frame index does (`FrameIndexer`),
    /// never through the result's in-memory `stdout`. That path reads the pipe only after the
    /// process exits, so anything past the ~64 KB pipe buffer deadlocks: measured, this
    /// probe hung for 10 minutes at 0 % CPU on the real fixture before the switch.
    static func sampledVideoBitrate(url: URL) async -> Int? {
        guard let ffprobe = try? FFTools.ffprobeURL() else { return nil }
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-bitrate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dump) }
        guard let output = try? await ProcessRunner.run(ffprobe, [
                  "-v", "error",
                  "-select_streams", "v:0",
                  "-read_intervals", "%+\(bitrateSampleSeconds)",
                  "-show_entries", "packet=pts_time,size",
                  "-print_format", "json",
                  url.path,
              ], stdoutTo: dump),
              output.status == 0,
              let json = try? Data(contentsOf: dump) else { return nil }
        return parseSampledBitrate(json: json)
    }

    /// Turns the sampled packet list into bits/sec. Pure, so the arithmetic is unit-testable
    /// off canned ffprobe output. Two quirks it has to survive: packets carry no `pts_time`
    /// at all on some MPEG-PS pictures (8 of 1500 on the real fixture), and they arrive in
    /// **decode** order, so the window is `max − min`, never last − first. That span covers
    /// the timed packets' presentation *instants*, one frame short of the content they
    /// represent, so it is scaled by `n/(n−1)` — the mean interval added back. All packet
    /// sizes count, timestamped or not: they are bytes the stream really spends.
    static func parseSampledBitrate(json: Data) -> Int? {
        guard let decoded = try? JSONDecoder().decode(FFPacketOutput.self, from: json) else { return nil }
        let bytes = decoded.packets.compactMap { $0.size.flatMap(Int.init) }.reduce(0, +)
        let times = decoded.packets.compactMap { $0.pts_time.flatMap(Double.init) }
        guard bytes > 0, times.count >= 2,
              let first = times.min(), let last = times.max() else { return nil }
        let span = (last - first) * Double(times.count) / Double(times.count - 1)
        guard span > 0 else { return nil }
        return Int((Double(bytes) * 8 / span).rounded())
    }

    /// Maps ffprobe's `-print_format json -show_streams -show_format` output to a
    /// `Result`: the first video stream, every audio stream in container order, and the
    /// format duration. Pure, so the mapping — including the case-varying tag keys —
    /// is unit-testable off canned ffprobe output.
    static func parseProbe(json: Data) throws -> Result {
        let decoded = try JSONDecoder().decode(FFProbeOutput.self, from: json)
        let v = decoded.streams.first { $0.codec_type == "video" }
        let audioStreams = decoded.streams.filter { $0.codec_type == "audio" }

        let video: VideoProperties? = v.map { (s: FFStream) -> VideoProperties in
            VideoProperties(
                codec: s.codec_name ?? "unknown",
                profile: s.profile,
                level: s.level.map(String.init),
                width: s.width ?? 0,
                height: s.height ?? 0,
                frameRate: s.avg_frame_rate ?? s.r_frame_rate ?? "",
                pixelFormat: s.pix_fmt ?? "",
                fieldOrder: s.field_order,
                sampleAspectRatio: s.sample_aspect_ratio,
                colorPrimaries: s.color_primaries,
                colorTransfer: s.color_transfer,
                colorSpace: s.color_space,
                colorRange: s.color_range,
                reorderDepth: s.has_b_frames,
                bitrate: s.bit_rate.flatMap(Int.init)
            )
        }

        let audioTracks = audioStreams.map { s in
            AudioProperties(
                codec: s.codec_name ?? "unknown",
                sampleRate: Int(s.sample_rate ?? "") ?? 0,
                channels: s.channels ?? 0,
                channelLayout: s.channel_layout,
                language: s.tags.tag("language"),
                title: s.tags.tag("title")
            )
        }

        let duration = decoded.format?.duration.flatMap(Double.init)
        // start_time rides in the same -show_format block (verified equal to the dedicated
        // `format=start_time` probe on real MPEG-PS/TS captures) — parsed through the same
        // rule as the CSV path so "N/A"/absent both land on 0 (issue #85).
        let containerStart = decoded.format?.start_time.map { parseStartTime(csv: $0) } ?? 0
        return Result(video: video, audio: audioTracks.first, audioTracks: audioTracks,
                      duration: duration, containerStart: containerStart,
                      videoCodecFrameRate: v?.r_frame_rate)
    }

    /// One source audio stream's repair-relevant facts (issue #52), in container order so
    /// the array index is the `0:a:N` map index. `profile` (e.g. "HE-AAC") and `bitrate`
    /// are not on `AudioProperties` — the Clip Doctor audio rebuild needs them to encode
    /// each track back in its own codec at its own bitrate, and to keep an HE-AAC track
    /// HE-AAC (the native `aac` encoder is LC-only).
    struct AudioStreamDetail: Equatable, Sendable {
        var codecName: String
        var profile: String?
        var sampleRate: Int
        var channels: Int
        /// Stream bit rate in bits/sec when the container reports it (TS broadcast
        /// captures usually do); nil when it doesn't.
        var bitrate: Int?
    }

    /// Every audio stream's repair-relevant facts in container order (issue #52). Uses the
    /// same `-show_streams` JSON as `probe` (the flat stream list, so a TS doesn't double-
    /// count). Returns `[]` on a probe failure — the caller treats that as "no audio".
    static func audioStreamDetails(url: URL) async -> [AudioStreamDetail] {
        guard let ffprobe = try? FFTools.ffprobeURL(),
              let output = try? await ProcessRunner.run(ffprobe, [
                  "-v", "quiet", "-print_format", "json", "-show_streams", url.path,
              ]),
              output.status == 0 else { return [] }
        return (try? parseAudioStreamDetails(json: output.stdout)) ?? []
    }

    /// Maps the `-show_streams` JSON to the audio streams' repair facts. Pure, so the
    /// codec/profile/bitrate mapping is unit-testable off canned ffprobe output.
    static func parseAudioStreamDetails(json: Data) throws -> [AudioStreamDetail] {
        let decoded = try JSONDecoder().decode(FFProbeOutput.self, from: json)
        return decoded.streams.filter { $0.codec_type == "audio" }.map { s in
            AudioStreamDetail(
                codecName: s.codec_name ?? "unknown",
                profile: s.profile,
                sampleRate: Int(s.sample_rate ?? "") ?? 0,
                channels: s.channels ?? 0,
                bitrate: s.bit_rate.flatMap(Int.init))
        }
    }

    /// A source stream Clip Doctor does **not** carry into the repaired file (ADR-0021,
    /// issue #53): the engine models only video + audio, so subtitle/teletext/data/
    /// attachment streams are dropped. Surfaced in the sheet so the omission is never
    /// silent. `kind` is ffprobe's `codec_type` ("subtitle", "data", …).
    struct OtherStream: Equatable, Sendable {
        var kind: String
        var codecName: String?
    }

    /// Every non-video, non-audio stream in container order (issue #53). Uses the same
    /// `-show_streams` JSON as `probe`/`audioStreamDetails`. Returns `[]` on a probe
    /// failure — a notice the caller can simply omit, never a blocker.
    static func nonAVStreams(url: URL) async -> [OtherStream] {
        guard let ffprobe = try? FFTools.ffprobeURL(),
              let output = try? await ProcessRunner.run(ffprobe, [
                  "-v", "quiet", "-print_format", "json", "-show_streams", url.path,
              ]),
              output.status == 0 else { return [] }
        return (try? parseNonAVStreams(json: output.stdout)) ?? []
    }

    /// Maps the `-show_streams` JSON to the streams Clip Doctor won't carry — anything
    /// that is neither video nor audio. Pure, so the mapping is unit-testable off canned
    /// ffprobe output.
    static func parseNonAVStreams(json: Data) throws -> [OtherStream] {
        let decoded = try JSONDecoder().decode(FFProbeOutput.self, from: json)
        return decoded.streams
            .filter { $0.codec_type != "video" && $0.codec_type != "audio" && $0.codec_type != nil }
            .map { OtherStream(kind: $0.codec_type ?? "data", codecName: $0.codec_name) }
    }

    /// The first video stream's timebase as ffprobe reports it (e.g. "1/16000"), or nil
    /// when the file has none or the probe fails. Read off the issue-#18 timescale probe
    /// piece to learn the MP4 track timescale stream-copied pieces of a source inherit.
    static func videoTimeBase(url: URL) async -> String? {
        guard let ffprobe = try? FFTools.ffprobeURL(),
              let output = try? await ProcessRunner.run(ffprobe, [
                  "-v", "error",
                  "-select_streams", "v:0",
                  "-show_entries", "stream=time_base",
                  "-of", "csv=p=0",
                  url.path,
              ]),
              output.status == 0,
              let text = String(data: output.stdout, encoding: .utf8) else { return nil }
        return parseTimeBase(csv: text)
    }

    /// Parses the `stream=time_base` CSV value to the bare "num/den" fact. ffprobe's csv
    /// writer leaves a trailing comma on MPEG-2 streams — stripped here so callers get
    /// the fact, not the quirk. Empty output (no video stream) is nil.
    static func parseTimeBase(csv: String) -> String? {
        let trimmed = csv.trimmingCharacters(in: CharacterSet(charactersIn: ", \n\r\t"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The container-level start_time in seconds — the offset ffmpeg measures input
    /// `-ss` from (the ADR-0013 trap; audio playback subtracts it to seek by source
    /// presentation time). 0 when the demuxer reports none ("N/A") or the probe fails;
    /// that's also the correct value for such files.
    ///
    /// A dedicated one-fact probe, kept for callers that need only start_time without a
    /// full `probe(url:)` (e.g. Clip Doctor's verify, the reopen copy-share warm-up). The
    /// import path does **not** use this — `probe(url:)` already surfaces the same value
    /// from its `-show_format` block, so importing needs no second launch (issue #85).
    static func containerStartTime(url: URL) async -> Double {
        guard let ffprobe = try? FFTools.ffprobeURL(),
              let output = try? await ProcessRunner.run(ffprobe, [
                  "-v", "error",
                  "-show_entries", "format=start_time",
                  "-of", "csv=p=0",
                  url.path,
              ]),
              output.status == 0,
              let text = String(data: output.stdout, encoding: .utf8) else { return 0 }
        return parseStartTime(csv: text)
    }

    /// Parses the `format=start_time` CSV value to seconds. "N/A" (the demuxer carries
    /// no start time) and anything unparseable are 0 — also the correct seek offset for
    /// such files.
    ///
    /// A negative value is clamped to 0 here, the single parse choke point every consumer
    /// reads `containerStart` through, so the whole app sees a start ≥ 0 by construction.
    /// The start is only ever used as a seek base — ffmpeg measures input `-ss` *from* it
    /// and can't seek before the file's first packet, and every seek builder subtracts it
    /// (`pts − start`); a negative start would push every seek *later* (`pts − (−x)`),
    /// over-seeking into content. ffprobe normalizes broadcast PTS wrap before it surfaces
    /// as `start_time`, so a genuinely negative container start has never been observed;
    /// treating one as "starts at 0" is the safe, meaningful reading.
    static func parseStartTime(csv: String) -> Double {
        max(0, Double(csv.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }
}

// MARK: - ffprobe JSON shapes

private struct FFProbeOutput: Decodable {
    var streams: [FFStream]
    var format: FFFormat?
}

private struct FFStream: Decodable {
    var codec_type: String?
    var codec_name: String?
    var profile: String?
    var level: Int?
    var width: Int?
    var height: Int?
    var avg_frame_rate: String?
    var r_frame_rate: String?
    var pix_fmt: String?
    var field_order: String?
    var sample_aspect_ratio: String?
    var color_primaries: String?
    var color_transfer: String?
    var color_space: String?
    var color_range: String?
    /// The stream's reorder depth (`VideoProperties.reorderDepth`, ADR-0026). Absent on
    /// audio streams and on demuxers that don't report it.
    var has_b_frames: Int?
    var sample_rate: String?
    var channels: Int?
    var channel_layout: String?
    var bit_rate: String?
    /// Container tags on the stream. Key case varies by container (Matroska reports
    /// lowercase, but not universally), so callers look up case-insensitively.
    var tags: [String: String]?
}

private extension Optional where Wrapped == [String: String] {
    /// Case-insensitive tag lookup; empty values count as absent.
    func tag(_ name: String) -> String? {
        guard let dict = self else { return nil }
        let hit = dict.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        return hit?.isEmpty == false ? hit : nil
    }
}

/// The `-show_entries packet=… -print_format json` shape the bitrate sample reads.
private struct FFPacketOutput: Decodable {
    var packets: [FFPacket]
}

private struct FFPacket: Decodable {
    /// Absent on pictures the demuxer carries no timestamp for (real on MPEG-PS).
    var pts_time: String?
    var size: String?
}

private struct FFFormat: Decodable {
    var duration: String?
    var start_time: String?
}
