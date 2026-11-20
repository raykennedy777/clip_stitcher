import Testing
@testable import ClipStitcher

struct EncoderSelectionTests {
    @Test func codecMapsToItsEncoder() {
        #expect(EncoderSelection.encoder(for: "hevc") == "libx265")
        #expect(EncoderSelection.encoder(for: "mpeg2video") == "mpeg2video")
        #expect(EncoderSelection.encoder(for: "h264") == "libx264")
        #expect(EncoderSelection.encoder(for: "vp9") == "libx264")
        #expect(EncoderSelection.encoder(for: nil) == "libx264")
    }

    @Test func profileTableFollowsTheEncoder() {
        #expect(EncoderSelection.profileCodec(for: "hevc") == "hevc")
        #expect(EncoderSelection.profileCodec(for: "mpeg2video") == "mpeg2video")
        #expect(EncoderSelection.profileCodec(for: "h264") == "h264")
        #expect(EncoderSelection.profileCodec(for: "vp9") == "h264")
        #expect(EncoderSelection.profileCodec(for: nil) == "h264")
    }

    @Test func knownProfilesMapToTheirEncoderTokens() {
        #expect(EncoderSelection.encoderProfile("Baseline", codec: "h264") == "baseline")
        #expect(EncoderSelection.encoderProfile("Constrained Baseline", codec: "h264") == "baseline")
        #expect(EncoderSelection.encoderProfile("High", codec: "h264") == "high")
        #expect(EncoderSelection.encoderProfile("Main 10", codec: "hevc") == "main10")
        #expect(EncoderSelection.encoderProfile("Main", codec: "mpeg2video") == "main")
        #expect(EncoderSelection.encoderProfile("4:2:2", codec: "mpeg2video") == "422")
    }

    @Test func unknownProfilesAreNilNeverGuessed() {
        #expect(EncoderSelection.encoderProfile(nil, codec: "h264") == nil)
        #expect(EncoderSelection.encoderProfile("Some Exotic Profile", codec: "h264") == nil)
        #expect(EncoderSelection.encoderProfile("Main 10", codec: "mpeg2video") == nil)
        #expect(EncoderSelection.encoderProfile("Main", codec: "vp9") == nil)
    }

    @Test func h264LevelTokenFromTheProbedInteger() {
        #expect(EncoderSelection.h264Level("40") == "4.0")
        #expect(EncoderSelection.h264Level("41") == "4.1")
        #expect(EncoderSelection.h264Level(nil) == nil)
        #expect(EncoderSelection.h264Level("High") == nil)
    }

    @Test func reorderDepthParamsSwitchThePyramidOnlyForAShallowJoin() {
        #expect(EncoderSelection.reorderDepthParams(depth: 1, forCodec: "h264") == ["b-pyramid=0"])
        #expect(EncoderSelection.reorderDepthParams(depth: 1, forCodec: "hevc") == ["b-pyramid=0"])
        #expect(EncoderSelection.reorderDepthParams(depth: 0, forCodec: "h264") == ["b-pyramid=0"])
        #expect(EncoderSelection.reorderDepthParams(depth: 2, forCodec: "h264") == [])
        #expect(EncoderSelection.reorderDepthParams(depth: 2, forCodec: "hevc") == [])
        #expect(EncoderSelection.reorderDepthParams(depth: 1, forCodec: "mpeg2video") == [])
        #expect(EncoderSelection.reorderDepthParams(depth: 2, forCodec: "mpeg2video") == [])
    }

    @Test func encoderParamsRideTheCodecsOwnFlag() {
        #expect(EncoderSelection.encoderParams(["b-pyramid=0"], forCodec: "h264")
            == ["-x264-params", "b-pyramid=0"])
        #expect(EncoderSelection.encoderParams(["b-pyramid=0"], forCodec: "hevc")
            == ["-x265-params", "b-pyramid=0"])
        #expect(EncoderSelection.encoderParams(["a=1", "b=2"], forCodec: "h264")
            == ["-x264-params", "a=1:b=2"])
        #expect(EncoderSelection.encoderParams([], forCodec: "h264") == [])
        #expect(EncoderSelection.encoderParams(["b-pyramid=0"], forCodec: "mpeg2video") == [])
    }

    @Test func encoderParamsMergeIntoAnExistingFlagNeverDuplicateIt() {
        let mbaff = ["-c:v", "libx264", "-x264-params", "ref=5:b-pyramid=0", "-bsf:v", "dump_extra"]
        #expect(EncoderSelection.withEncoderParams(["keyint=25"], in: mbaff, forCodec: "h264")
            == ["-c:v", "libx264", "-x264-params", "ref=5:b-pyramid=0:keyint=25",
                "-bsf:v", "dump_extra"])
        let plain = ["-c:v", "libx265", "-pix_fmt", "yuv420p10le"]
        #expect(EncoderSelection.withEncoderParams(["b-pyramid=0"], in: plain, forCodec: "hevc")
            == plain + ["-x265-params", "b-pyramid=0"])
        #expect(EncoderSelection.withEncoderParams([], in: plain, forCodec: "hevc") == plain)
    }

    @Test func hevcLevelIdcFromGeneralLevelIdc() {
        #expect(EncoderSelection.hevcLevel("123") == "4.1")
        #expect(EncoderSelection.hevcLevel("120") == "4.0")
        #expect(EncoderSelection.hevcLevel("93") == "3.1")
        #expect(EncoderSelection.hevcLevel(nil) == nil)
        #expect(EncoderSelection.hevcLevel("Main") == nil)
    }
}
