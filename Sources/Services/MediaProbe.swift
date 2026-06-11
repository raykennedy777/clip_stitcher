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
        return try parseProbe(json: output.stdout)
    }

    /// Maps ffprobe's `-print_format json -show_streams -show_format` output to a
    /// `Result`: the first video stream, every audio stream in container order, and the
    /// format duration. Pure, so the mapping — including the case-varying tag keys —
    /// is unit-testable off canned ffprobe output.
    static func parseProbe(json: Data) throws -> Result {
        let decoded = try JSONDecoder().decode(FFProbeOutput.self, from: json)
        let v = decoded.streams.first { $0.codec_type == "video" }
        let audioStreams = decoded.streams.filter { $0.codec_type == "audio" }

        let video = v.map { s in
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
                colorRange: s.color_range
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
        return Result(video: video, audio: audioTracks.first, audioTracks: audioTracks, duration: duration)
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
    static func parseStartTime(csv: String) -> Double {
        Double(csv.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
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
    var sample_rate: String?
    var channels: Int?
    var channel_layout: String?
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

private struct FFFormat: Decodable {
    var duration: String?
}
