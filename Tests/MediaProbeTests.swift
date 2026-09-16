import Testing
import Foundation
@testable import ClipStitcher

/// Exercises MediaProbe's pure parsers against canned ffprobe output — the JSON
/// stream/format probe and the two CSV facts (container start time, video timebase) —
/// including the known quirks: ffprobe's CSV writer emits a trailing comma on MPEG-2
/// streams, and reports "N/A" for values a demuxer doesn't carry.
struct MediaProbeTests {

    // MARK: JSON probe parsing

    /// Trimmed real `ffprobe -print_format json -show_streams -show_format` shape:
    /// one video stream, two audio streams with container tags, format duration.
    private let cannedJSON = Data("""
    {
        "streams": [
            {
                "codec_type": "video",
                "codec_name": "mpeg2video",
                "profile": "Main",
                "level": 8,
                "width": 704,
                "height": 576,
                "avg_frame_rate": "25/1",
                "r_frame_rate": "25/1",
                "pix_fmt": "yuv420p",
                "field_order": "tt",
                "sample_aspect_ratio": "16:11",
                "color_primaries": "bt470bg",
                "color_transfer": "bt470bg",
                "color_space": "bt470bg",
                "color_range": "tv"
            },
            {
                "codec_type": "audio",
                "codec_name": "mp2",
                "sample_rate": "48000",
                "channels": 2,
                "channel_layout": "stereo",
                "bit_rate": "384000",
                "tags": { "LANGUAGE": "eng", "title": "World Feed" }
            },
            {
                "codec_type": "audio",
                "codec_name": "ac3",
                "sample_rate": "44100",
                "channels": 1,
                "tags": { "language": "" }
            }
        ],
        "format": { "duration": "4020.160000" }
    }
    """.utf8)

    @Test func parseProbeMapsStreamsAndFormat() throws {
        let result = try MediaProbe.parseProbe(json: cannedJSON)
        #expect(result.video == VideoProperties(
            codec: "mpeg2video", profile: "Main", level: "8", width: 704, height: 576,
            frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: "tt",
            sampleAspectRatio: "16:11", colorPrimaries: "bt470bg",
            colorTransfer: "bt470bg", colorSpace: "bt470bg", colorRange: "tv"))
        #expect(result.audioTracks.count == 2)
        // the legacy single-track field stays filled with the first stream (ADR-0014)
        #expect(result.audio == result.audioTracks.first)
        #expect(result.duration == 4020.16)
    }

    @Test func parseProbeReadsTagsCaseInsensitivelyAndDropsEmptyValues() throws {
        let result = try MediaProbe.parseProbe(json: cannedJSON)
        // Matroska reports lowercase tag keys, but not universally — "LANGUAGE" still hits.
        #expect(result.audioTracks[0].language == "eng")
        #expect(result.audioTracks[0].title == "World Feed")
        // an empty tag value counts as absent
        #expect(result.audioTracks[1].language == nil)
        #expect(result.audioTracks[1].title == nil)
    }

    /// An audio stream's own reported `bit_rate` rides on `AudioProperties` (issue #115), so
    /// a plan query can print the source rate beside the fixed output rate. Absent on a
    /// container that reports none — nil, never a guess.
    @Test func parseProbeReadsAudioBitrateWhenReported() throws {
        let result = try MediaProbe.parseProbe(json: cannedJSON)
        #expect(result.audioTracks[0].bitrate == 384_000)
        #expect(result.audioTracks[1].bitrate == nil)
    }

    @Test func parseProbeFillsMissingFieldsWithDefaults() throws {
        let json = Data("""
        { "streams": [ { "codec_type": "video" }, { "codec_type": "audio" } ] }
        """.utf8)
        let result = try MediaProbe.parseProbe(json: json)
        #expect(result.video?.codec == "unknown")
        #expect(result.video?.width == 0 && result.video?.height == 0)
        #expect(result.audioTracks[0].codec == "unknown")
        #expect(result.audioTracks[0].sampleRate == 0 && result.audioTracks[0].channels == 0)
        #expect(result.duration == nil)
    }

    @Test func parseProbeWithoutAVideoStreamHasNoVideo() throws {
        let json = Data("""
        { "streams": [ { "codec_type": "audio", "codec_name": "aac" } ] }
        """.utf8)
        let result = try MediaProbe.parseProbe(json: json)
        #expect(result.video == nil)
        #expect(result.audioTracks.count == 1)
    }

    // MARK: video bitrate (re-encode rate control, #110)

    /// The **video stream's** own reported `bit_rate` rides on `VideoProperties` — the number
    /// an MPEG-2 re-encode targets. Never the format-level bit rate, which includes the audio
    /// tracks' share (2.67 vs 2.53 Mbps on the real MPEG-PS fixture).
    @Test func parseProbeCarriesTheVideoStreamBitrateNotTheFormats() throws {
        let json = Data("""
        {"streams":[
          {"codec_type":"video","codec_name":"h264","bit_rate":"2453976"},
          {"codec_type":"audio","codec_name":"aac","bit_rate":"128157"}
        ],"format":{"bit_rate":"2588393"}}
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: json).video?.bitrate == 2_453_976)
    }

    /// MPEG-PS carries no video-stream `bit_rate` at all — the field is absent, and stays nil
    /// rather than 0, so the sample (or the fixed-quantiser fallback) takes over.
    @Test func parseProbeLeavesAnUnreportedVideoBitrateNil() throws {
        let json = Data("""
        {"streams":[ {"codec_type":"video","codec_name":"mpeg2video"} ]}
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: json).video?.bitrate == nil)
    }

    /// The bounded packet sample: all packet sizes count, and the window is `max − min` of
    /// the timed packets scaled by `n/(n−1)` — packets arrive in *decode* order, so last −
    /// first is not the span, and the timed instants run one frame short of the content they
    /// represent. 30000 bytes over four 25 fps packets ⇒ 0.16 s ⇒ 1.5 Mbps.
    @Test func parseSampledBitrateSumsPacketSizesOverTheTimedSpan() {
        let json = Data("""
        {"packets":[
          {"pts_time":"0.540000","size":"10000"},
          {"pts_time":"0.620000","size":"5000"},
          {"pts_time":"0.580000","size":"5000"},
          {"pts_time":"0.660000","size":"10000"}
        ]}
        """.utf8)
        #expect(MediaProbe.parseSampledBitrate(json: json) == 1_500_000)
    }

    /// A packet the demuxer carries no timestamp for (8 of 1500 on the real MPEG-PS fixture)
    /// still contributes its bytes — they are bits the stream really spends — it just can't
    /// widen the span.
    @Test func parseSampledBitrateCountsBytesOfUntimestampedPackets() {
        let json = Data("""
        {"packets":[
          {"pts_time":"0.000000","size":"10000"},
          {"size":"5000"},
          {"pts_time":"0.080000","size":"10000"}
        ]}
        """.utf8)
        #expect(MediaProbe.parseSampledBitrate(json: json) == 1_250_000)   // 25000 B / 0.16 s
    }

    /// Too little to measure a span, or nothing to measure at all, is nil — never a bogus
    /// bitrate. The caller then falls back to the fixed quantiser.
    @Test func parseSampledBitrateIsNilWhenThereIsNoMeasurableSpan() {
        #expect(MediaProbe.parseSampledBitrate(json: Data("{\"packets\":[]}".utf8)) == nil)
        #expect(MediaProbe.parseSampledBitrate(json: Data("""
        {"packets":[ {"pts_time":"1.000000","size":"10000"} ]}
        """.utf8)) == nil)
        // every packet at the same instant: a zero span can't divide
        #expect(MediaProbe.parseSampledBitrate(json: Data("""
        {"packets":[ {"pts_time":"1.0","size":"10"}, {"pts_time":"1.0","size":"10"} ]}
        """.utf8)) == nil)
        #expect(MediaProbe.parseSampledBitrate(json: Data("not json".utf8)) == nil)
    }

    // MARK: audio stream details (Clip Doctor repair audio rebuild, #52)

    /// `parseAudioStreamDetails` keeps only the audio streams, in container order, and
    /// carries the codec/profile/sample-rate/channels/bitrate the in-codec rebuild needs —
    /// notably the profile (HE-AAC must stay HE-AAC) and the source bitrate when reported.
    @Test func parseAudioStreamDetailsKeepsAudioWithRepairFacts() throws {
        let json = Data("""
        {"streams":[
          {"codec_type":"video","codec_name":"h264"},
          {"codec_type":"audio","codec_name":"aac","profile":"HE-AAC",
           "sample_rate":"48000","channels":2,"bit_rate":"95970"},
          {"codec_type":"audio","codec_name":"mp2",
           "sample_rate":"48000","channels":2,"bit_rate":"384000"},
          {"codec_type":"subtitle","codec_name":"dvb_teletext"}
        ]}
        """.utf8)
        let details = try MediaProbe.parseAudioStreamDetails(json: json)
        #expect(details == [
            MediaProbe.AudioStreamDetail(codecName: "aac", profile: "HE-AAC",
                                         sampleRate: 48000, channels: 2, bitrate: 95970),
            MediaProbe.AudioStreamDetail(codecName: "mp2", profile: nil,
                                         sampleRate: 48000, channels: 2, bitrate: 384000),
        ])
    }

    /// Missing fields take the same defaults as the rest of the probe: unknown codec, a
    /// zero sample-rate/channels, and — crucially — a nil bitrate (not zero) so the repair
    /// can fall back to a per-channel default rather than encoding at 0 bits/sec.
    @Test func parseAudioStreamDetailsDefaultsMissingFieldsAndNilsAbsentBitrate() throws {
        let json = Data("""
        {"streams":[ {"codec_type":"audio"} ]}
        """.utf8)
        let details = try MediaProbe.parseAudioStreamDetails(json: json)
        #expect(details == [
            MediaProbe.AudioStreamDetail(codecName: "unknown", profile: nil,
                                         sampleRate: 0, channels: 0, bitrate: nil),
        ])
    }

    @Test func parseAudioStreamDetailsIsEmptyWithoutAnyAudio() throws {
        let json = Data(#"{"streams":[ {"codec_type":"video","codec_name":"h264"} ]}"#.utf8)
        #expect(try MediaProbe.parseAudioStreamDetails(json: json) == [])
    }

    // MARK: container start_time folded into the JSON probe (issue #85)

    @Test func parseProbeReadsContainerStartFromShowFormat() throws {
        // The `-show_format` block already carries start_time (verified equal to the dedicated
        // `format=start_time` probe on real captures), so the import path needs no second probe.
        let json = Data("""
        { "streams": [ { "codec_type": "video", "codec_name": "h264" } ],
          "format": { "duration": "10.0", "start_time": "1.480000" } }
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: json).containerStart == 1.48)
    }

    @Test func parseProbeTreatsAbsentOrNAContainerStartAsZero() throws {
        // Absent format.start_time and an explicit "N/A" both map to 0 — the same rule the CSV
        // path uses, and the correct seek offset for such files.
        let absent = Data("""
        { "streams": [ { "codec_type": "video" } ], "format": { "duration": "10.0" } }
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: absent).containerStart == 0)
        let na = Data("""
        { "streams": [ { "codec_type": "video" } ], "format": { "start_time": "N/A" } }
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: na).containerStart == 0)
    }

    // MARK: container start_time CSV (issue #3)

    @Test func parseStartTimeReadsTheOffsetSeconds() {
        // the measured MPEG-PS case: a 0.24 s container start (the input -ss trap)
        #expect(MediaProbe.parseStartTime(csv: "0.240000\n") == 0.24)
    }

    @Test func parseStartTimeTreatsNAAsZero() {
        // a demuxer with no start time reports "N/A" — 0 is also the correct seek offset
        #expect(MediaProbe.parseStartTime(csv: "N/A\n") == 0)
        #expect(MediaProbe.parseStartTime(csv: "") == 0)
    }

    @Test func parseStartTimeClampsANegativeStartToZero() {
        // A negative container start is never a meaningful seek base (ffmpeg measures input
        // -ss *from* it and can't seek before the first packet; a negative would over-seek).
        // Clamped here, the single choke point every `containerStart` consumer reads (#86).
        #expect(MediaProbe.parseStartTime(csv: "-0.500000\n") == 0)
    }

    @Test func negativeStartTimeInTheJSONProbeClampsToZero() throws {
        // Same clamp reached via the folded -show_format path (issue #85 + #86).
        let json = Data("""
        { "streams": [ { "codec_type": "video" } ], "format": { "start_time": "-1.200000" } }
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: json).containerStart == 0)
    }

    // MARK: video timebase CSV (issue #18)

    @Test func parseTimeBaseReturnsTheBareFraction() {
        #expect(MediaProbe.parseTimeBase(csv: "1/16000\n") == "1/16000")
    }

    @Test func parseTimeBaseStripsTheMpeg2TrailingComma() {
        // ffprobe's csv writer leaves a trailing comma on MPEG-2 streams
        #expect(MediaProbe.parseTimeBase(csv: "1/90000,\n") == "1/90000")
    }

    @Test func parseTimeBaseIsNilWhenTheFileHasNoVideoStream() {
        #expect(MediaProbe.parseTimeBase(csv: "") == nil)
        #expect(MediaProbe.parseTimeBase(csv: "\n") == nil)
    }
}
