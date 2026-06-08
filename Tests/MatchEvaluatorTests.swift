import Testing
import Foundation
@testable import VidConform

/// Exercises the smart-render-vs-conform match verdict (ADR-0005), focusing on the audio
/// rule: audio *codec* is no longer compared (the track is always rebuilt to the target's
/// codec, so the source codec can't block video smart-render — ADR-0010), but sample rate
/// and channels still are (the rebuild preserves them rather than resampling).
struct MatchEvaluatorTests {
    private func video(codec: String = "h264", width: Int = 1920) -> VideoProperties {
        VideoProperties(codec: codec, profile: "High", level: "40", width: width, height: 1080,
                        frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: "progressive",
                        sampleAspectRatio: "1:1", colorPrimaries: "bt709", colorTransfer: "bt709",
                        colorRange: "tv")
    }
    private func audio(codec: String = "aac", rate: Int = 48000, channels: Int = 2) -> AudioProperties {
        AudioProperties(codec: codec, sampleRate: rate, channels: channels, channelLayout: "stereo")
    }
    private func clip(video: VideoProperties?, audio: AudioProperties?) -> Clip {
        Clip(bookmark: Data(), displayName: "c", video: video, audio: audio)
    }

    @Test func audioCodecMismatchAloneStillMatches() {
        // The round-trip bug: an mp2 source exported (and re-encoded) to aac re-imports with
        // identical video + rate + channels, differing only in codec. It must smart-render.
        let target = clip(video: video(), audio: audio(codec: "mp2"))
        let reimported = clip(video: video(), audio: audio(codec: "aac"))
        #expect(MatchEvaluator.matches(reimported, target: target))
    }

    @Test func audioSampleRateMismatchFailsTheMatch() {
        let target = clip(video: video(), audio: audio(rate: 48000))
        let other = clip(video: video(), audio: audio(rate: 44100))
        #expect(!MatchEvaluator.matches(other, target: target))
    }

    @Test func audioChannelCountMismatchFailsTheMatch() {
        let target = clip(video: video(), audio: audio(channels: 2))
        let other = clip(video: video(), audio: audio(channels: 1))
        #expect(!MatchEvaluator.matches(other, target: target))
    }

    @Test func identicalClipsMatch() {
        let target = clip(video: video(), audio: audio())
        #expect(MatchEvaluator.matches(clip(video: video(), audio: audio()), target: target))
    }

    @Test func videoMismatchFailsRegardlessOfAudio() {
        let target = clip(video: video(width: 1920), audio: audio())
        let other = clip(video: video(width: 1280), audio: audio())
        #expect(!MatchEvaluator.matches(other, target: target))
    }

    @Test func oneSideMissingAudioFailsTheMatch() {
        // A missing audio stream can't feed the concat — still a mismatch.
        let target = clip(video: video(), audio: audio())
        #expect(!MatchEvaluator.matches(clip(video: video(), audio: nil), target: target))
    }

    @Test func bothMissingAudioMatchWhenVideoMatches() {
        let target = clip(video: video(), audio: nil)
        #expect(MatchEvaluator.matches(clip(video: video(), audio: nil), target: target))
    }
}
