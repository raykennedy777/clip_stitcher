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

    @Test func scanIsComparedByDirectionNotBySpelling() {
        // Issue #119: ffprobe's `tt` and `tb` are one coded stream read in two containers —
        // ffmpeg 9 tags every interlaced encode `tb`/`bt` and only Matroska stores the tag, so
        // a `tt` target was unreachable by any conform. Top-first is top-first.
        #expect(MatchEvaluator.scanDirection("tt") == "tff")
        #expect(MatchEvaluator.scanDirection("tb") == "tff")
        #expect(MatchEvaluator.scanDirection("bb") == "bff")
        #expect(MatchEvaluator.scanDirection("bt") == "bff")
        #expect(MatchEvaluator.scanDirection(nil) == "progressive")
        #expect(MatchEvaluator.scanDirection("unknown") == "progressive")
        let tt = video(field: "tt")
        #expect(MatchEvaluator.conformedVideoMatches(video(field: "tb"), tt))
        #expect(MatchEvaluator.videoMatches(video(field: "tb"), tt))
        #expect(MatchEvaluator.conformedVideoMatches(video(field: "bt"), video(field: "bb")))
        #expect(MatchEvaluator.matches(clip(video: video(field: "tb"), audio: nil),
                                       target: clip(video: tt, audio: nil)))
        // A genuine scan difference still fails loudly, in both gates.
        #expect(!MatchEvaluator.conformedVideoMatches(video(field: "bb"), tt))
        #expect(!MatchEvaluator.conformedVideoMatches(video(field: "bt"), video(field: "tb")))
        #expect(!MatchEvaluator.conformedVideoMatches(video(field: "progressive"), tt))
        #expect(!MatchEvaluator.conformedVideoMatches(tt, video(field: nil)))
        #expect(!MatchEvaluator.videoMatches(video(field: "bb"), tt))
        // The plan's reason line names the two spellings, so a reader sees what was probed.
        let diffs = MatchEvaluator.videoDifferences(video(field: "bb"), tt)
        #expect(diffs.map(\.label) == ["Scan type"])
        #expect(diffs.first?.clipValue == "Interlaced (bb)")
        #expect(MatchEvaluator.videoDifferences(video(field: "tb"), tt).isEmpty)
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

    // MARK: - Per-property difference list (issue #88)

    /// A fully-tagged base so every strict-compare field has a value to mutate, including the
    /// colour matrix (`colorSpace`), which the shared `video()` leaves nil.
    private func tagged() -> VideoProperties {
        VideoProperties(codec: "h264", profile: "High", level: "40", width: 1920, height: 1080,
                        frameRate: "25/1", pixelFormat: "yuv420p", fieldOrder: "progressive",
                        sampleAspectRatio: "1:1", colorPrimaries: "bt709", colorTransfer: "bt709",
                        colorSpace: "bt709", colorRange: "tv")
    }

    /// The Bool verdict and the difference list are one source of truth: for every mutation the
    /// list is empty exactly when `videoMatches` is true. This is the invariant the inspector
    /// leans on to never disagree with the routing verdict.
    @Test func differencesEmptyIffVideoMatches() {
        let base = tagged()
        var mutations: [VideoProperties] = [base]  // identical → matches, empty list
        mutations.append({ var v = base; v.codec = "hevc"; return v }())
        mutations.append({ var v = base; v.profile = "Main"; return v }())
        mutations.append({ var v = base; v.level = "41"; return v }())
        mutations.append({ var v = base; v.width = 1280; return v }())
        mutations.append({ var v = base; v.height = 720; return v }())
        mutations.append({ var v = base; v.frameRate = "30000/1001"; return v }())
        mutations.append({ var v = base; v.pixelFormat = "yuv422p"; return v }())
        mutations.append({ var v = base; v.fieldOrder = "tt"; return v }())
        mutations.append({ var v = base; v.sampleAspectRatio = "16:15"; return v }())
        mutations.append({ var v = base; v.colorPrimaries = "bt470bg"; return v }())
        mutations.append({ var v = base; v.colorTransfer = "smpte170m"; return v }())
        mutations.append({ var v = base; v.colorSpace = "bt470bg"; return v }())
        mutations.append({ var v = base; v.colorRange = "pc"; return v }())
        for cv in mutations {
            #expect(MatchEvaluator.videoDifferences(cv, base).isEmpty == MatchEvaluator.videoMatches(cv, base))
        }
    }

    /// Each single-field mutation surfaces exactly one named difference — the label the
    /// inspector shows. Width and height fold into one "Dimensions" difference by design.
    @Test func eachPropertyProducesOneNamedDifference() {
        let base = tagged()
        func onlyDiff(_ mutate: (inout VideoProperties) -> Void) -> MatchEvaluator.VideoDifference? {
            var v = base; mutate(&v)
            let diffs = MatchEvaluator.videoDifferences(v, base)
            return diffs.count == 1 ? diffs[0] : nil
        }
        #expect(onlyDiff { $0.codec = "hevc" }?.label == "Codec")
        #expect(onlyDiff { $0.profile = "Main" }?.label == "Profile")
        #expect(onlyDiff { $0.level = "41" }?.label == "Level")
        #expect(onlyDiff { $0.width = 1280 }?.label == "Dimensions")
        #expect(onlyDiff { $0.height = 720 }?.label == "Dimensions")
        #expect(onlyDiff { $0.frameRate = "30000/1001" }?.label == "Frame rate")
        #expect(onlyDiff { $0.pixelFormat = "yuv422p" }?.label == "Pixel format")
        #expect(onlyDiff { $0.fieldOrder = "tt" }?.label == "Scan type")
        #expect(onlyDiff { $0.sampleAspectRatio = "16:15" }?.label == "Pixel aspect ratio")
        #expect(onlyDiff { $0.colorPrimaries = "bt470bg" }?.label == "Color primaries")
        #expect(onlyDiff { $0.colorTransfer = "smpte170m" }?.label == "Color transfer")
        #expect(onlyDiff { $0.colorSpace = "bt470bg" }?.label == "Color matrix")
        #expect(onlyDiff { $0.colorRange = "pc" }?.label == "Color range")
    }

    /// The named values read the way the inspector shows them: the frame rate is the
    /// formatted fps, so "30000/1001 → 25/1" surfaces as "29.970 → 25".
    @Test func frameRateDifferenceFormatsBothValues() {
        var cv = tagged(); cv.frameRate = "30000/1001"
        let diff = MatchEvaluator.videoDifferences(cv, tagged()).first
        #expect(diff?.label == "Frame rate")
        #expect(diff?.clipValue == "29.970")
        #expect(diff?.targetValue == "25")
    }

    /// The normalized scan-type compare carries into the list: a missing field order equals
    /// progressive (no difference), an interlaced order does not.
    @Test func scanTypeDifferenceHonoursNormalization() {
        var progressive = tagged(); progressive.fieldOrder = nil
        #expect(MatchEvaluator.videoDifferences(progressive, tagged()).isEmpty)
        var interlaced = tagged(); interlaced.fieldOrder = "tt"
        let diff = MatchEvaluator.videoDifferences(interlaced, tagged()).first
        #expect(diff?.label == "Scan type")
        #expect(diff?.clipValue == "Interlaced (tt)")
        #expect(diff?.targetValue == "Progressive")
    }

    /// Several mismatched fields accumulate in canonical order — no early exit.
    @Test func multipleDifferencesAccumulateInOrder() {
        var cv = tagged()
        cv.width = 1280
        cv.frameRate = "50/1"
        cv.colorRange = "pc"
        let labels = MatchEvaluator.videoDifferences(cv, tagged()).map(\.label)
        #expect(labels == ["Dimensions", "Frame rate", "Color range"])
    }

    /// The clip-level convenience agrees with `matches` for two video-bearing clips, and
    /// yields an empty list when either lacks probed video (the inspector guards that case).
    @Test func clipDifferencesAgreeWithMatches() {
        let target = clip(video: tagged(), audio: audio())
        var mismatchVideo = tagged(); mismatchVideo.width = 640
        let mismatch = clip(video: mismatchVideo, audio: audio())
        #expect(MatchEvaluator.differences(mismatch, target: target).isEmpty == MatchEvaluator.matches(mismatch, target: target))
        let same = clip(video: tagged(), audio: audio())
        #expect(MatchEvaluator.differences(same, target: target).isEmpty)
        #expect(MatchEvaluator.matches(same, target: target))
        // Missing video: no comparison, empty list (matches() is false, guarded in the UI).
        let noVideo = clip(video: nil, audio: audio())
        #expect(MatchEvaluator.differences(noVideo, target: target).isEmpty)
        #expect(!MatchEvaluator.matches(noVideo, target: target))
    }

    // MARK: - Inspector Match verdict (issue #88)

    /// The pure seam the inspector renders. For every non-target clip the verdict's
    /// `willSmartRender` must equal `matches(clip, target)` — the inspector can never contradict
    /// the router. The pinned case is a target with no probed video: `differences` returns []
    /// there, so the old inspector fell through to a bogus "matches", while the router re-encodes.
    @Test func matchVerdictAgreesWithRouterForEveryNonTargetClip() {
        let withVideo = clip(video: tagged(), audio: audio())
        let noVideo = clip(video: nil, audio: audio())
        var mismatchVideo = tagged(); mismatchVideo.width = 640
        let mismatch = clip(video: mismatchVideo, audio: audio())

        // No target set.
        #expect(MatchEvaluator.matchVerdict(for: withVideo, target: nil) == .noTarget)

        // This clip is the target.
        #expect(MatchEvaluator.matchVerdict(for: withVideo, target: withVideo) == .isTarget)

        // Target with no probed video: routes to re-encode, and the verdict names it so — the
        // regression fix. willSmartRender must equal matches().
        let noVideoTarget = clip(video: nil, audio: audio())
        let vsNoVideoTarget = MatchEvaluator.matchVerdict(for: withVideo, target: noVideoTarget)
        #expect(vsNoVideoTarget == .targetHasNoVideo)
        #expect(vsNoVideoTarget.willSmartRender == MatchEvaluator.matches(withVideo, target: noVideoTarget))

        // Clip with no video against a video-bearing target.
        let videoTarget = clip(video: tagged(), audio: audio())
        let vsClipNoVideo = MatchEvaluator.matchVerdict(for: noVideo, target: videoTarget)
        #expect(vsClipNoVideo == .clipHasNoVideo)
        #expect(vsClipNoVideo.willSmartRender == MatchEvaluator.matches(noVideo, target: videoTarget))

        // A clean match smart-renders.
        let match = clip(video: tagged(), audio: audio())
        let vsMatch = MatchEvaluator.matchVerdict(for: match, target: videoTarget)
        #expect(vsMatch == .smartRender)
        #expect(vsMatch.willSmartRender == MatchEvaluator.matches(match, target: videoTarget))

        // A property mismatch re-encodes and carries the difference list.
        let vsMismatch = MatchEvaluator.matchVerdict(for: mismatch, target: videoTarget)
        #expect(vsMismatch == .reEncode(MatchEvaluator.differences(mismatch, target: videoTarget)))
        #expect(vsMismatch.willSmartRender == MatchEvaluator.matches(mismatch, target: videoTarget))
    }
}
