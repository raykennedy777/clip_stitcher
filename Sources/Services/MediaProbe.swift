import Foundation

enum MediaProbe {
    struct Result: Codable, Equatable, Sendable {
        var video: VideoProperties?
        var audio: AudioProperties?
        var audioTracks: [AudioProperties] = []
        var duration: Double?
        var containerStart: Double = 0
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
        if result.video?.codec == "mpeg2video", result.video?.bitrate == nil {
            result.video?.bitrate = await sampledVideoBitrate(url: url)
        }
        return result
    }

    static let bitrateSampleSeconds = 60

    static func sampledVideoBitrate(url: URL) async -> Int? {
        guard let ffprobe = try? FFTools.ffprobeURL() else { return nil }
        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstitcher-bitrate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dump) }
        guard let output = try? await ProcessRunner.run(ffprobe, [
                  "-v", "error",
                  "-select_streams", "v:0",
                  // ADR-0009
                  "-read_intervals", "%+\(bitrateSampleSeconds)",
                  "-show_entries", "packet=pts_time,size",
                  "-print_format", "json",
                  url.path,
              ], stdoutTo: dump),
              output.status == 0,
              let json = try? Data(contentsOf: dump) else { return nil }
        return parseSampledBitrate(json: json)
    }

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
                title: s.tags.tag("title"),
                bitrate: s.bit_rate.flatMap(Int.init)
            )
        }

        let duration = decoded.format?.duration.flatMap(Double.init)
        let containerStart = decoded.format?.start_time.map { parseStartTime(csv: $0) } ?? 0
        return Result(video: video, audio: audioTracks.first, audioTracks: audioTracks,
                      duration: duration, containerStart: containerStart,
                      videoCodecFrameRate: v?.r_frame_rate)
    }

    struct AudioStreamDetail: Equatable, Sendable {
        var codecName: String
        var profile: String?
        var sampleRate: Int
        var channels: Int
        var bitrate: Int?
    }

    static func audioStreamDetails(url: URL) async -> [AudioStreamDetail] {
        guard let ffprobe = try? FFTools.ffprobeURL(),
              let output = try? await ProcessRunner.run(ffprobe, [
                  "-v", "quiet", "-print_format", "json", "-show_streams", url.path,
              ]),
              output.status == 0 else { return [] }
        return (try? parseAudioStreamDetails(json: output.stdout)) ?? []
    }

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

    struct AudioTimeline: Equatable, Sendable {
        var streamIndex: Int
        var timedPackets: Int
        var untimedPackets: Int = 0
        var firstPts: Double? = nil
        var lastPts: Double? = nil
        var firstNonAdvance: NonAdvance? = nil

        struct NonAdvance: Equatable, Sendable {
            var ordinal: Int
            var previous: Double
            var pts: Double
        }

        var span: Double? {
            guard timedPackets >= 2, let first = firstPts, let last = lastPts else { return nil }
            return last - first
        }

        var packetInterval: Double? {
            guard let span, timedPackets >= 2, span > 0 else { return nil }
            return span / Double(timedPackets - 1)
        }

        func extent(nominalInterval: Double) -> Double? {
            guard let first = firstPts, let last = lastPts else { return nil }
            return (last - first) + (packetInterval ?? nominalInterval)
        }
    }

    static func audioTimelines(url: URL) async throws -> [AudioTimeline] {
        let ffprobe = try FFTools.ffprobeURL()
        let live = LiveAudioTimelines()
        let output = try await ProcessRunner.run(ffprobe, [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "packet=stream_index,pts_time",
            "-of", "csv=p=0",
            url.path,
        ], onStdout: { live.feed($0) })
        guard output.status == 0 else {
            throw FFError.probeFailed(String(data: output.stderr, encoding: .utf8) ?? "exit \(output.status)")
        }
        return live.finish()
    }

    struct StreamingAudioTimelines {
        private var lines = LineAssembler()
        private var tracks: [Int: AudioTimeline] = [:]

        mutating func feed(_ chunk: String) {
            for line in lines.feed(chunk) { ingest(line) }
        }

        mutating func finish() -> [AudioTimeline] {
            if let last = lines.finish() { ingest(last) }
            return tracks.values.sorted { $0.streamIndex < $1.streamIndex }
        }

        private mutating func ingest(_ line: String) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2, let streamIndex = Int(fields[0]) else { return }
            var track = tracks[streamIndex] ?? AudioTimeline(streamIndex: streamIndex,
                                                             timedPackets: 0)
            defer { tracks[streamIndex] = track }
            guard let pts = Double(fields[1]) else {
                track.untimedPackets += 1
                return
            }
            if let previous = track.lastPts, pts <= previous, track.firstNonAdvance == nil {
                track.firstNonAdvance = AudioTimeline.NonAdvance(
                    ordinal: track.timedPackets + 1, previous: previous, pts: pts)
            }
            track.timedPackets += 1
            if track.firstPts == nil { track.firstPts = pts }
            track.lastPts = pts
        }
    }

    static func parseAudioTimelines(csv: String) -> [AudioTimeline] {
        var parse = StreamingAudioTimelines()
        parse.feed(csv)
        return parse.finish()
    }

    struct OtherStream: Equatable, Sendable {
        var kind: String
        var codecName: String?
    }

    static func nonAVStreams(url: URL) async -> [OtherStream] {
        guard let ffprobe = try? FFTools.ffprobeURL(),
              let output = try? await ProcessRunner.run(ffprobe, [
                  "-v", "quiet", "-print_format", "json", "-show_streams", url.path,
              ]),
              output.status == 0 else { return [] }
        return (try? parseNonAVStreams(json: output.stdout)) ?? []
    }

    static func parseNonAVStreams(json: Data) throws -> [OtherStream] {
        let decoded = try JSONDecoder().decode(FFProbeOutput.self, from: json)
        return decoded.streams
            .filter { $0.codec_type != "video" && $0.codec_type != "audio" && $0.codec_type != nil }
            .map { OtherStream(kind: $0.codec_type ?? "data", codecName: $0.codec_name) }
    }

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

    static func parseTimeBase(csv: String) -> String? {
        let trimmed = csv.trimmingCharacters(in: CharacterSet(charactersIn: ", \n\r\t"))
        return trimmed.isEmpty ? nil : trimmed
    }

    // ADR-0011
    static func codedFieldOrder(url: URL, frames: Int = 3) async -> String? {
        guard let ffprobe = try? FFTools.ffprobeURL(),
              let output = try? await ProcessRunner.run(ffprobe, [
                  "-v", "error", "-select_streams", "v:0", "-show_frames",
                  "-show_entries", "frame=interlaced_frame,top_field_first",
                  "-of", "csv=p=0", "-read_intervals", "%+#\(frames)",
                  url.path,
              ]),
              output.status == 0,
              let text = String(data: output.stdout, encoding: .utf8) else { return nil }
        return parseCodedFieldOrder(csv: text)
    }

    static func parseCodedFieldOrder(csv: String) -> String? {
        let tokens = csv.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2 else { return nil }
            if f[0] != "1" { return "progressive" }
            return f[1] == "1" ? "tt" : "bb"
        }
        guard let first = tokens.first, tokens.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

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

    // ADR-0015
    static func parseStartTime(csv: String) -> Double {
        max(0, Double(csv.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }
}

final class LiveAudioTimelines: @unchecked Sendable {
    private var parse = MediaProbe.StreamingAudioTimelines()
    private let lock = NSLock()

    func feed(_ data: Data) {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        lock.lock()
        defer { lock.unlock() }
        parse.feed(text)
    }

    func finish() -> [MediaProbe.AudioTimeline] {
        lock.lock()
        defer { lock.unlock() }
        return parse.finish()
    }
}

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
    var has_b_frames: Int?
    var sample_rate: String?
    var channels: Int?
    var channel_layout: String?
    var bit_rate: String?
    var tags: [String: String]?
}

private extension Optional where Wrapped == [String: String] {
    func tag(_ name: String) -> String? {
        guard let dict = self else { return nil }
        let hit = dict.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        return hit?.isEmpty == false ? hit : nil
    }
}

private struct FFPacketOutput: Decodable {
    var packets: [FFPacket]
}

private struct FFPacket: Decodable {
    var pts_time: String?
    var size: String?
}

private struct FFFormat: Decodable {
    var duration: String?
    var start_time: String?
}
