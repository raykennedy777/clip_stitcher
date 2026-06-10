import Testing
@testable import VidConform

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

    @Test func hevcLevelIdcFromGeneralLevelIdc() {
        // HEVC's probed level is general_level_idc = level × 30: 123 → 4.1, 120 → 4.0
        #expect(EncoderSelection.hevcLevel("123") == "4.1")
        #expect(EncoderSelection.hevcLevel("120") == "4.0")
        #expect(EncoderSelection.hevcLevel("93") == "3.1")
        #expect(EncoderSelection.hevcLevel(nil) == nil)
        #expect(EncoderSelection.hevcLevel("Main") == nil)
    }
}
