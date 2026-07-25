import Testing
@testable import ClipStitcher

/// Pins the shared encoder-selection tables (issue #29) both re-encode paths build
/// from: codec → encoder, profile-string → -profile:v token, and the level tokens.
/// The full argument arrays they feed stay pinned in the two engines' own tests.
struct EncoderSelectionTests {

    @Test func codecMapsToItsEncoder() {
        #expect(EncoderSelection.encoder(for: "hevc") == "libx265")
        #expect(EncoderSelection.encoder(for: "mpeg2video") == "mpeg2video")
        #expect(EncoderSelection.encoder(for: "h264") == "libx264")
        // any codec without its own entry re-encodes as H.264
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
        // a wrong -profile:v token aborts the encode, so unrecognised input maps to nil
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

    // MARK: reorder depth (ADR-0026, issue #106)

    /// A shallow join drops the encoders' default B-pyramid; a deep one keeps it (the
    /// default already produces depth 2). MPEG-2 has no pyramid to switch off.
    @Test func reorderDepthParamsSwitchThePyramidOnlyForAShallowJoin() {
        #expect(EncoderSelection.reorderDepthParams(depth: 1, forCodec: "h264") == ["b-pyramid=0"])
        #expect(EncoderSelection.reorderDepthParams(depth: 1, forCodec: "hevc") == ["b-pyramid=0"])
        #expect(EncoderSelection.reorderDepthParams(depth: 0, forCodec: "h264") == ["b-pyramid=0"])
        #expect(EncoderSelection.reorderDepthParams(depth: 2, forCodec: "h264") == [])
        #expect(EncoderSelection.reorderDepthParams(depth: 2, forCodec: "hevc") == [])
        // MPEG-2's B-frames never reference other B-frames: nothing to say, either way.
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
        // Nothing to carry, and a codec with no such flag, both emit no args.
        #expect(EncoderSelection.encoderParams([], forCodec: "h264") == [])
        #expect(EncoderSelection.encoderParams(["b-pyramid=0"], forCodec: "mpeg2video") == [])
    }

    /// ffmpeg honours only the last `-x264-params`, so entries merge into an existing flag
    /// (Clip Doctor's MBAFF repair args carry their own) rather than being appended twice.
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
        // HEVC's probed level is general_level_idc = level × 30: 123 → 4.1, 120 → 4.0
        #expect(EncoderSelection.hevcLevel("123") == "4.1")
        #expect(EncoderSelection.hevcLevel("120") == "4.0")
        #expect(EncoderSelection.hevcLevel("93") == "3.1")
        #expect(EncoderSelection.hevcLevel(nil) == nil)
        #expect(EncoderSelection.hevcLevel("Main") == nil)
    }
}
