import Testing
import Foundation
@testable import ClipStitcher

struct MediaProbeTests {
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
        #expect(result.audio == result.audioTracks.first)
        #expect(result.duration == 4020.16)
    }

    @Test func parseProbeReadsTagsCaseInsensitivelyAndDropsEmptyValues() throws {
        let result = try MediaProbe.parseProbe(json: cannedJSON)
        #expect(result.audioTracks[0].language == "eng")
        #expect(result.audioTracks[0].title == "World Feed")
        #expect(result.audioTracks[1].language == nil)
        #expect(result.audioTracks[1].title == nil)
    }

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

    @Test func parseProbeCarriesTheVideoStreamBitrateNotTheFormats() throws {
        let json = Data("""
        {"streams":[
          {"codec_type":"video","codec_name":"h264","bit_rate":"2453976"},
          {"codec_type":"audio","codec_name":"aac","bit_rate":"128157"}
        ],"format":{"bit_rate":"2588393"}}
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: json).video?.bitrate == 2_453_976)
    }

    @Test func parseProbeLeavesAnUnreportedVideoBitrateNil() throws {
        let json = Data("""
        {"streams":[ {"codec_type":"video","codec_name":"mpeg2video"} ]}
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: json).video?.bitrate == nil)
    }

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

    @Test func parseSampledBitrateCountsBytesOfUntimestampedPackets() {
        let json = Data("""
        {"packets":[
          {"pts_time":"0.000000","size":"10000"},
          {"size":"5000"},
          {"pts_time":"0.080000","size":"10000"}
        ]}
        """.utf8)
        #expect(MediaProbe.parseSampledBitrate(json: json) == 1_250_000)
    }

    @Test func parseSampledBitrateIsNilWhenThereIsNoMeasurableSpan() {
        #expect(MediaProbe.parseSampledBitrate(json: Data("{\"packets\":[]}".utf8)) == nil)
        #expect(MediaProbe.parseSampledBitrate(json: Data("""
        {"packets":[ {"pts_time":"1.000000","size":"10000"} ]}
        """.utf8)) == nil)
        #expect(MediaProbe.parseSampledBitrate(json: Data("""
        {"packets":[ {"pts_time":"1.0","size":"10"}, {"pts_time":"1.0","size":"10"} ]}
        """.utf8)) == nil)
        #expect(MediaProbe.parseSampledBitrate(json: Data("not json".utf8)) == nil)
    }

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

    @Test func parseProbeReadsContainerStartFromShowFormat() throws {
        let json = Data("""
        { "streams": [ { "codec_type": "video", "codec_name": "h264" } ],
          "format": { "duration": "10.0", "start_time": "1.480000" } }
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: json).containerStart == 1.48)
    }

    @Test func parseProbeTreatsAbsentOrNAContainerStartAsZero() throws {
        let absent = Data("""
        { "streams": [ { "codec_type": "video" } ], "format": { "duration": "10.0" } }
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: absent).containerStart == 0)
        let na = Data("""
        { "streams": [ { "codec_type": "video" } ], "format": { "start_time": "N/A" } }
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: na).containerStart == 0)
    }

    @Test func parseCodedFieldOrderReadsTheFrameFlags() {
        #expect(MediaProbe.parseCodedFieldOrder(csv: "1,1\n1,1\n1,1,\n") == "tt")
        #expect(MediaProbe.parseCodedFieldOrder(csv: "1,0\n1,0\n") == "bb")
        #expect(MediaProbe.parseCodedFieldOrder(csv: "0,0\n0,0\n") == "progressive")
        #expect(MediaProbe.parseCodedFieldOrder(csv: "1,1\n0,0\n") == nil)
        #expect(MediaProbe.parseCodedFieldOrder(csv: "") == nil)
    }

    @Test func parseStartTimeReadsTheOffsetSeconds() {
        #expect(MediaProbe.parseStartTime(csv: "0.240000\n") == 0.24)
    }

    @Test func parseStartTimeTreatsNAAsZero() {
        #expect(MediaProbe.parseStartTime(csv: "N/A\n") == 0)
        #expect(MediaProbe.parseStartTime(csv: "") == 0)
    }

    @Test func parseStartTimeClampsANegativeStartToZero() {
        #expect(MediaProbe.parseStartTime(csv: "-0.500000\n") == 0)
    }

    @Test func negativeStartTimeInTheJSONProbeClampsToZero() throws {
        let json = Data("""
        { "streams": [ { "codec_type": "video" } ], "format": { "start_time": "-1.200000" } }
        """.utf8)
        #expect(try MediaProbe.parseProbe(json: json).containerStart == 0)
    }

    @Test func parseTimeBaseReturnsTheBareFraction() {
        #expect(MediaProbe.parseTimeBase(csv: "1/16000\n") == "1/16000")
    }

    @Test func parseTimeBaseStripsTheMpeg2TrailingComma() {
        #expect(MediaProbe.parseTimeBase(csv: "1/90000,\n") == "1/90000")
    }

    @Test func parseTimeBaseIsNilWhenTheFileHasNoVideoStream() {
        #expect(MediaProbe.parseTimeBase(csv: "") == nil)
        #expect(MediaProbe.parseTimeBase(csv: "\n") == nil)
    }
}
