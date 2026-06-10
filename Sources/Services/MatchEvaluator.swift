import Foundation

/// Decides whether a clip can be smart-rendered against the target clip, applying
/// the strict matching rule from ADR-0005. Any difference in the compared
/// properties means the clip must be fully re-encoded (conformed) to the target.
enum MatchEvaluator {
    static func matches(_ clip: Clip, target: Clip) -> Bool {
        guard let cv = clip.video, let tv = target.video else { return false }

        // Audio is deliberately not compared at all (ADR-0014): every audio leg is
        // rebuilt and conformed to its output track's codec/rate/layout inside the
        // rebuild chain, so no audio property of a source can force a video re-encode.
        return videoMatches(cv, tv)
    }

    /// Compares the video properties alone on the strict dimensions (ADR-0005). Exposed so a
    /// conformed video piece — which carries no audio yet — can be verified against the
    /// target's video spec before the audio is muxed in (ADR-0011).
    static func videoMatches(_ cv: VideoProperties, _ tv: VideoProperties) -> Bool {
        cv.codec == tv.codec &&
        cv.profile == tv.profile &&
        cv.level == tv.level &&
        cv.width == tv.width &&
        cv.height == tv.height &&
        cv.frameRate == tv.frameRate &&
        cv.pixelFormat == tv.pixelFormat &&
        normalizedFieldOrder(cv.fieldOrder) == normalizedFieldOrder(tv.fieldOrder) &&
        cv.sampleAspectRatio == tv.sampleAspectRatio &&
        cv.colorPrimaries == tv.colorPrimaries &&
        cv.colorTransfer == tv.colorTransfer &&
        cv.colorRange == tv.colorRange
    }

    /// Whether a conformed output satisfies its target for the self-verify gate (ADR-0011). The
    /// stricter dimensions are exact, exactly as `videoMatches`, but a color dimension the target
    /// leaves UNSPECIFIED (nil) imposes no requirement: conform strips the output's color tags
    /// best-effort, yet some are intrinsic to the encoder/container (libx264 + Matroska always
    /// signal limited `tv` range), and an unspecified target plays back under that same default —
    /// so the residual tag is not a real difference. A color dimension the target DOES specify must
    /// still match, so a *differently* color-tagged target is still caught loudly (true color-aware
    /// conversion remains a TODO). The strict `videoMatches` still drives smart-render routing.
    static func conformedVideoMatches(_ output: VideoProperties, _ target: VideoProperties) -> Bool {
        output.codec == target.codec &&
        output.profile == target.profile &&
        output.level == target.level &&
        output.width == target.width &&
        output.height == target.height &&
        output.frameRate == target.frameRate &&
        output.pixelFormat == target.pixelFormat &&
        normalizedFieldOrder(output.fieldOrder) == normalizedFieldOrder(target.fieldOrder) &&
        output.sampleAspectRatio == target.sampleAspectRatio &&
        colorSatisfies(output.colorPrimaries, target: target.colorPrimaries) &&
        colorSatisfies(output.colorTransfer, target: target.colorTransfer) &&
        colorSatisfies(output.colorRange, target: target.colorRange)
    }

    /// A target color field that is unspecified (nil) imposes no requirement on the conformed
    /// output; a specified one must match exactly.
    static func colorSatisfies(_ output: String?, target: String?) -> Bool {
        target == nil || output == target
    }

    /// Canonicalises an ffprobe `field_order` for comparison and conform targeting: a missing,
    /// empty, or "unknown" value means progressive (a clean progressive HEVC stream often
    /// reports no field order at all, so the target clip would otherwise be unmatchable even
    /// by a copy of itself — ADR-0011). Interlaced values (`tt`/`bb`/`tb`/`bt`) are returned
    /// unchanged, so a real scan-type difference still fails the match.
    static func normalizedFieldOrder(_ value: String?) -> String {
        switch value {
        case nil, "", "unknown", "progressive": return "progressive"
        default: return value!
        }
    }
}
