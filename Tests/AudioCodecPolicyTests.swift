import Testing
import Foundation
@testable import ClipStitcher

struct AudioCodecPolicyTests {
    @Test func resolvesToTargetCodecWhenContainerAllowsIt() {
        let choice = AudioCodecPolicy.resolveAudioCodec(targetCodec: "mp2", container: .ts)
        #expect(choice == AudioCodecPolicy.AudioEncodeChoice(codec: "mp2", encoder: "mp2", fellBack: false))
        #expect(AudioCodecPolicy.resolveAudioCodec(targetCodec: "mp3", container: .mkv).encoder == "libmp3lame")
    }

    @Test func fallsBackToAACForMp2InMp4() {
        let choice = AudioCodecPolicy.resolveAudioCodec(targetCodec: "mp2", container: .mp4)
        #expect(choice == AudioCodecPolicy.AudioEncodeChoice(codec: "aac", encoder: "aac", fellBack: true))
    }

    @Test func fallsBackToAACForAnUnmappableCodec() {
        let choice = AudioCodecPolicy.resolveAudioCodec(targetCodec: "dts", container: .mkv)
        #expect(choice.encoder == "aac" && choice.fellBack)
    }

    @Test func anAACTargetUsesAACWithoutFlaggingAFallback() {
        #expect(AudioCodecPolicy.resolveAudioCodec(targetCodec: "aac", container: .mp4)
                == AudioCodecPolicy.AudioEncodeChoice(codec: "aac", encoder: "aac", fellBack: false))
    }

    @Test func noTargetAudioDefaultsToAACWithoutAWarning() {
        #expect(AudioCodecPolicy.resolveAudioCodec(targetCodec: nil, container: .ts)
                == AudioCodecPolicy.AudioEncodeChoice(codec: "aac", encoder: "aac", fellBack: false))
    }

    @Test func audioOnlyKeepsTheTargetCodecRegardlessOfContainer() {
        #expect(AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: "mp2")
                == AudioCodecPolicy.AudioEncodeChoice(codec: "mp2", encoder: "mp2", fellBack: false))
        let dts = AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: "dts")
        #expect(dts.encoder == "aac" && dts.fellBack)
        #expect(AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: nil)
                == AudioCodecPolicy.AudioEncodeChoice(codec: "aac", encoder: "aac", fellBack: false))
    }

    @Test func audioOnlyExtensionFollowsTheEncoder() {
        #expect(AudioCodecPolicy.audioFileExtension(forEncoder: "aac") == "m4a")
        #expect(AudioCodecPolicy.audioFileExtension(forEncoder: "mp2") == "mp2")
        #expect(AudioCodecPolicy.audioFileExtension(forEncoder: "ac3") == "ac3")
        #expect(AudioCodecPolicy.audioFileExtension(forEncoder: "libmp3lame") == "mp3")
    }

    @Test func outputExtensionUsesAudioExtForAudioOnlyElseContainer() {
        #expect(AudioCodecPolicy.outputExtension(type: .audioOnly, container: .mp4, audioEncoder: "mp2") == "mp2")
        #expect(AudioCodecPolicy.outputExtension(type: .videoAndAudio, container: .ts, audioEncoder: "mp2") == "ts")
        #expect(AudioCodecPolicy.outputExtension(type: .videoOnly, container: .mkv, audioEncoder: "aac") == "mkv")
    }
}
