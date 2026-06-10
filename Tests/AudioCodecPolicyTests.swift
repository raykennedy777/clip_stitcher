import Testing
import Foundation
@testable import VidConform

/// Exercises the audio codec policy — which codec the rebuilt audio encodes to
/// (ADR-0010), the extensions that follow from it, and which output audio tracks an
/// export carries (ADR-0014). Moved verbatim from the export engine's test surface
/// when the policy was extracted (issue #25).
struct AudioCodecPolicyTests {

    // MARK: output track resolution (ADR-0014)

    private func clipWithTracks(_ tracks: [AudioProperties]) -> Clip {
        var c = Clip(bookmark: Data(), displayName: "c")
        c.audio = tracks.first
        c.audioTracks = tracks
        return c
    }

    @Test func outputTrackCountIsTheRichestClips() {
        let a = AudioProperties(codec: "aac", sampleRate: 48000, channels: 2)
        let clips = [clipWithTracks([a]), clipWithTracks([a, a, a]), clipWithTracks([a, a])]
        let tracks = AudioCodecPolicy.resolveOutputTracks(target: clips[0], clips: clips)
        #expect(tracks.count == 3)
    }

    @Test func trackFormatComesFromTheTargetFirstThenTimelineOrder() {
        let mono = AudioProperties(codec: "mp2", sampleRate: 44100, channels: 1, language: "eng", title: "Eurosport")
        let stereo = AudioProperties(codec: "aac", sampleRate: 48000, channels: 2, language: "spa", title: "TVE")
        let other = AudioProperties(codec: "ac3", sampleRate: 32000, channels: 2)
        // target carries one track; the second output track's spec falls to the first
        // clip in timeline order that has one.
        let target = clipWithTracks([mono])
        let clips = [clipWithTracks([other]), clipWithTracks([other, stereo])]
        let tracks = AudioCodecPolicy.resolveOutputTracks(target: target, clips: clips)
        #expect(tracks == [
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 44100, channels: 1, language: "eng", title: "Eurosport"),
            AudioCodecPolicy.OutputAudioTrack(sampleRate: 48000, channels: 2, language: "spa", title: "TVE"),
        ])
    }

    @Test func noAudioAnywhereResolvesToNoTracks() {
        let clips = [clipWithTracks([]), clipWithTracks([])]
        #expect(AudioCodecPolicy.resolveOutputTracks(target: nil, clips: clips).isEmpty)
    }

    // MARK: audio codec resolution (ADR-0010)

    @Test func resolvesToTargetCodecWhenContainerAllowsIt() {
        // mp2 source -> TS: keep mp2, map to its encoder, no fallback warning.
        let choice = AudioCodecPolicy.resolveAudioCodec(targetCodec: "mp2", container: .ts)
        #expect(choice == AudioCodecPolicy.AudioEncodeChoice(codec: "mp2", encoder: "mp2", fellBack: false))
        // mp3 maps to libmp3lame.
        #expect(AudioCodecPolicy.resolveAudioCodec(targetCodec: "mp3", container: .mkv).encoder == "libmp3lame")
    }

    @Test func fallsBackToAACForMp2InMp4() {
        // The one awkward combo: mp2 can't sit cleanly in MP4, so fall back + flag a warning.
        let choice = AudioCodecPolicy.resolveAudioCodec(targetCodec: "mp2", container: .mp4)
        #expect(choice == AudioCodecPolicy.AudioEncodeChoice(codec: "aac", encoder: "aac", fellBack: true))
    }

    @Test func fallsBackToAACForAnUnmappableCodec() {
        let choice = AudioCodecPolicy.resolveAudioCodec(targetCodec: "dts", container: .mkv)
        #expect(choice.encoder == "aac" && choice.fellBack)
    }

    @Test func anAACTargetUsesAACWithoutFlaggingAFallback() {
        // No codec was declined, so no warning.
        #expect(AudioCodecPolicy.resolveAudioCodec(targetCodec: "aac", container: .mp4)
                == AudioCodecPolicy.AudioEncodeChoice(codec: "aac", encoder: "aac", fellBack: false))
    }

    @Test func noTargetAudioDefaultsToAACWithoutAWarning() {
        #expect(AudioCodecPolicy.resolveAudioCodec(targetCodec: nil, container: .ts)
                == AudioCodecPolicy.AudioEncodeChoice(codec: "aac", encoder: "aac", fellBack: false))
    }

    // MARK: audio-only output (#1)

    @Test func audioOnlyKeepsTheTargetCodecRegardlessOfContainer() {
        // No video container to fit — mp2 stays mp2 even though it wouldn't fit MP4 video.
        #expect(AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: "mp2")
                == AudioCodecPolicy.AudioEncodeChoice(codec: "mp2", encoder: "mp2", fellBack: false))
        // An unmappable codec still falls back to AAC and flags it.
        let dts = AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: "dts")
        #expect(dts.encoder == "aac" && dts.fellBack)
        // No target audio -> AAC, no warning.
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
        // audio-only ignores the video container and follows the codec.
        #expect(AudioCodecPolicy.outputExtension(type: .audioOnly, container: .mp4, audioEncoder: "mp2") == "mp2")
        // video outputs keep the container extension.
        #expect(AudioCodecPolicy.outputExtension(type: .videoAndAudio, container: .ts, audioEncoder: "mp2") == "ts")
        #expect(AudioCodecPolicy.outputExtension(type: .videoOnly, container: .mkv, audioEncoder: "aac") == "mkv")
    }
}
