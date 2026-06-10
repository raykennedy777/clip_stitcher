import Testing
import Foundation
@testable import VidConform

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
                "color_range": "tv"
            },
            {
                "codec_type": "audio",
                "codec_name": "mp2",
                "sample_rate": "48000",
                "channels": 2,
                "channel_layout": "stereo",
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
            colorTransfer: "bt470bg", colorRange: "tv"))
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
