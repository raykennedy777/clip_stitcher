import Testing
import Foundation
@testable import ClipStitcher

/// Exercises the smart-render-vs-conform match verdict (ADR-0005). Audio is not compared
/// at all (ADR-0014): every audio leg is rebuilt and conformed to its output track's
/// codec/rate/layout, so no audio property can block video smart-render.
struct MatchEvaluatorTests {
    private func video(codec: String = "h264", width: Int = 1920,
                       field: String? = "progressive") -> VideoProperties {
        VideoProperties(codec: codec, profile: "High", level: "40", width: width, height: 1080,
                        frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: field,
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

    @Test func noAudioPropertyBlocksTheMatch() {
        // ADR-0014: every audio leg is conformed to its output track's format inside the
        // rebuild chain, so rate/channel differences — and missing audio entirely — can
        // no longer force a video re-encode.
        let target = clip(video: video(), audio: audio(rate: 48000, channels: 2))
        #expect(MatchEvaluator.matches(clip(video: video(), audio: audio(rate: 44100)), target: target))
        #expect(MatchEvaluator.matches(clip(video: video(), audio: audio(channels: 1)), target: target))
        #expect(MatchEvaluator.matches(clip(video: video(), audio: nil), target: target))
    }

    @Test func identicalClipsMatch() {
        let target = clip(video: video(), audio: audio())
        #expect(MatchEvaluator.matches(clip(video: video(), audio: audio()), target: target))
    }

    @Test func missingFieldOrderMatchesProgressive() {
        // The HEVC target probes field_order=None; a clean progressive encode reports
        // "progressive". They are the same scan type, so they must match — otherwise the
        // HEVC clip is unmatchable even by a copy of itself (ADR-0011 normalization).
        let target = clip(video: video(field: nil), audio: audio())
        let progressive = clip(video: video(field: "progressive"), audio: audio())
        #expect(MatchEvaluator.matches(progressive, target: target))
    }

    @Test func interlacedStillMismatchesProgressive() {
        // Normalization only collapses missing/unknown ≡ progressive; a genuine scan-type
        // difference (tt vs progressive) must still force a conform.
        let target = clip(video: video(field: "progressive"), audio: audio())
        let interlaced = clip(video: video(field: "tt"), audio: audio())
        #expect(!MatchEvaluator.matches(interlaced, target: target))
        #expect(MatchEvaluator.normalizedFieldOrder("tt") == "tt")
        #expect(MatchEvaluator.normalizedFieldOrder("unknown") == "progressive")
    }

    @Test func videoMatchesComparesVideoDimensionsAlone() {
        // The conform self-verify checks a produced video piece (which has no audio) against
        // the target's video spec, so the video comparison is exposed on its own.
        #expect(MatchEvaluator.videoMatches(video(), video()))
        #expect(!MatchEvaluator.videoMatches(video(width: 1280), video(width: 1920)))
        #expect(MatchEvaluator.videoMatches(video(field: nil), video(field: "progressive")))
    }

    @Test func conformedMatchIgnoresColorTheUntaggedTargetDoesNotSpecify() {
        // The MKV→untagged-SD case: libx264 + Matroska always stamp limited `tv` range, so a
        // conformed piece keeps `range=tv` even after the strip. An untagged target specifies no
        // colour, so that residual tag must NOT fail the conform self-verify.
        let untagged = VideoProperties(
            codec: "h264", profile: "High", level: "40", width: 704, height: 528,
            frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: "progressive",
            sampleAspectRatio: "1:1", colorPrimaries: nil, colorTransfer: nil, colorRange: nil)
        var output = untagged; output.colorRange = "tv"
        #expect(MatchEvaluator.conformedVideoMatches(output, untagged))
        // A non-colour mismatch still fails.
        var wrongSize = output; wrongSize.width = 1280
        #expect(!MatchEvaluator.conformedVideoMatches(wrongSize, untagged))
    }

    @Test func conformedMatchStillEnforcesColorTheTargetSpecifies() {
        // The loud-fail backstop: when the target DOES carry colour, a differently-tagged output
        // must still fail (true conversion is deferred), so we never ship a colour-wrong clip.
        let tagged = video()   // bt709 / bt709 / tv
        var wrongColor = tagged; wrongColor.colorPrimaries = "bt470bg"
        #expect(!MatchEvaluator.conformedVideoMatches(wrongColor, tagged))
        #expect(MatchEvaluator.conformedVideoMatches(tagged, tagged))
        #expect(MatchEvaluator.colorSatisfies(nil, target: nil))
        #expect(MatchEvaluator.colorSatisfies("tv", target: nil))
        #expect(!MatchEvaluator.colorSatisfies(nil, target: "tv"))
    }

    @Test func matrixJoinsTheStrictCompareAndTheConformGate() {
        // Issue #35: the YUV matrix (ffprobe color_space) is the third leg of the colour
        // triple. A matrix-only difference between stream-copied neighbours is a visible
        // colour shift at the join, so it forces a conform like the other colour dimensions.
        var hybrid = video()   // bt709 primaries/transfer…
        hybrid.colorSpace = "bt470bg"   // …but a BT.601 matrix — the France 2005 shape
        #expect(!MatchEvaluator.videoMatches(hybrid, video()))
        #expect(MatchEvaluator.videoMatches(hybrid, hybrid))
        // The conform gate mirrors the other colour fields: a target without a matrix tag
        // imposes none; a tagged one must be met.
        #expect(MatchEvaluator.conformedVideoMatches(hybrid, video()))
        #expect(!MatchEvaluator.conformedVideoMatches(video(), hybrid))
    }

    @Test func videoMismatchFailsRegardlessOfAudio() {
        let target = clip(video: video(width: 1920), audio: audio())
        let other = clip(video: video(width: 1280), audio: audio())
        #expect(!MatchEvaluator.matches(other, target: target))
    }

    @Test func bothMissingAudioMatchWhenVideoMatches() {
        let target = clip(video: video(), audio: nil)
        #expect(MatchEvaluator.matches(clip(video: video(), audio: nil), target: target))
    }
}
