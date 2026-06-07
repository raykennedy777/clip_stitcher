import Foundation

/// Probes a media file with ffprobe and maps the result to our property types.
enum MediaProbe {
    struct Result: Sendable {
        var video: VideoProperties?
        var audio: AudioProperties?
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

        let decoded = try JSONDecoder().decode(FFProbeOutput.self, from: output.stdout)
        let v = decoded.streams.first { $0.codec_type == "video" }
        let a = decoded.streams.first { $0.codec_type == "audio" }

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
                colorRange: s.color_range
            )
        }

        let audio = a.map { s in
            AudioProperties(
                codec: s.codec_name ?? "unknown",
                sampleRate: Int(s.sample_rate ?? "") ?? 0,
                channels: s.channels ?? 0,
                channelLayout: s.channel_layout
            )
        }

        let duration = decoded.format?.duration.flatMap(Double.init)
        return Result(video: video, audio: audio, duration: duration)
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
    var color_range: String?
    var sample_rate: String?
    var channels: Int?
    var channel_layout: String?
}

private struct FFFormat: Decodable {
    var duration: String?
}
