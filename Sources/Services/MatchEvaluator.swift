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
    ///
    /// Derived from `videoDifferences` so the verdict and the inspector's per-property
    /// mismatch list (issue #88) come from one comparison — they can never disagree.
    static func videoMatches(_ cv: VideoProperties, _ tv: VideoProperties) -> Bool {
        videoDifferences(cv, tv).isEmpty
    }

    /// One strict-compare video property whose value differs between a clip and the target,
    /// named and value-formatted for display (issue #88).
    struct VideoDifference: Equatable {
        /// The human property name, e.g. "Frame rate".
        let label: String
        /// The clip's value, display-formatted (e.g. "25").
        let clipValue: String
        /// The target's value, display-formatted (e.g. "29.997").
        let targetValue: String
    }

    /// Every strict-compare (ADR-0005) video property on which `cv` differs from the target
    /// `tv`, in the canonical compare order. This is the single source of truth for both the
    /// smart-render routing verdict (`videoMatches` = this list is empty) and the inspector's
    /// "why it doesn't match" section, so the two can never drift.
    ///
    /// The comparison operators are exactly those the strict rule uses: raw equality on every
    /// field, but `scanDirection` on scan type (a clean progressive stream may report no field
    /// order — ADR-0011 — and `tt`/`tb` are one direction spelled two ways — issue #119) and the
    /// color matrix included as the third color leg (issue #35).
    static func videoDifferences(_ cv: VideoProperties, _ tv: VideoProperties) -> [VideoDifference] {
        var diffs: [VideoDifference] = []
        func check(_ label: String, equal: Bool,
                   _ clipValue: @autoclosure () -> String, _ targetValue: @autoclosure () -> String) {
            if !equal {
                diffs.append(VideoDifference(label: label, clipValue: clipValue(), targetValue: targetValue()))
            }
        }
        check("Codec", equal: cv.codec == tv.codec, cv.codec.uppercased(), tv.codec.uppercased())
        check("Profile", equal: cv.profile == tv.profile, display(cv.profile), display(tv.profile))
        check("Level", equal: cv.level == tv.level, display(cv.level), display(tv.level))
        // Width and height are two strict fields but one user-facing property: any difference in
        // either surfaces as a single "Dimensions" mismatch.
        check("Dimensions", equal: cv.width == tv.width && cv.height == tv.height,
              "\(cv.width)×\(cv.height)", "\(tv.width)×\(tv.height)")
        check("Frame rate", equal: cv.frameRate == tv.frameRate,
              MediaFormatting.frameRate(cv.frameRate), MediaFormatting.frameRate(tv.frameRate))
        check("Pixel format", equal: cv.pixelFormat == tv.pixelFormat, cv.pixelFormat, tv.pixelFormat)
        check("Scan type", equal: scanDirection(cv.fieldOrder) == scanDirection(tv.fieldOrder),
              MediaFormatting.scanType(cv.fieldOrder), MediaFormatting.scanType(tv.fieldOrder))
        check("Pixel aspect ratio", equal: cv.sampleAspectRatio == tv.sampleAspectRatio,
              display(cv.sampleAspectRatio), display(tv.sampleAspectRatio))
        check("Color primaries", equal: cv.colorPrimaries == tv.colorPrimaries,
              display(cv.colorPrimaries), display(tv.colorPrimaries))
        check("Color transfer", equal: cv.colorTransfer == tv.colorTransfer,
              display(cv.colorTransfer), display(tv.colorTransfer))
        check("Color matrix", equal: cv.colorSpace == tv.colorSpace,
              display(cv.colorSpace), display(tv.colorSpace))
        check("Color range", equal: cv.colorRange == tv.colorRange,
              display(cv.colorRange), display(tv.colorRange))
        return diffs
    }

    /// The strict-compare video differences between a clip and the target, for the inspector's
    /// Match section (issue #88). Empty when they match (⟺ `matches` for two video-bearing
    /// clips); also empty — with no meaningful comparison — when either clip lacks probed video,
    /// which `matchVerdict` guards separately (it names the missing video rather than a match).
    static func differences(_ clip: Clip, target: Clip) -> [VideoDifference] {
        guard let cv = clip.video, let tv = target.video else { return [] }
        return videoDifferences(cv, tv)
    }

    /// The inspector's Match-section verdict for a clip against the project's target, as a pure
    /// value (issue #88). The single source the view renders, so the explanation it shows can
    /// never disagree with the smart-render router: for every non-target clip,
    /// `verdict.willSmartRender == matches(clip, target)`. In particular a target with no probed
    /// video routes to re-encode (`matches` = false because `differences` sees no target video),
    /// and this verdict names that case rather than falling through to a bogus "matches".
    enum MatchVerdict: Equatable {
        /// The clip *is* the target — nothing to compare.
        case isTarget
        /// No target clip is set for the project.
        case noTarget
        /// The clip has no probed video track to compare.
        case clipHasNoVideo
        /// The target has no probed video track yet, so nothing can match it (→ re-encode).
        case targetHasNoVideo
        /// Every strict property matches — the clip smart-renders.
        case smartRender
        /// The clip differs on the listed properties — it re-encodes.
        case reEncode([VideoDifference])

        /// Whether this verdict routes to a copy/smart-render rather than a re-encode. Equals
        /// `matches(clip, target)` for every non-target clip, pinning the inspector to the router.
        var willSmartRender: Bool {
            if case .smartRender = self { return true }
            return false
        }
    }

    static func matchVerdict(for clip: Clip, target: Clip?) -> MatchVerdict {
        guard let target else { return .noTarget }
        if target.id == clip.id { return .isTarget }
        guard clip.video != nil else { return .clipHasNoVideo }
        guard target.video != nil else { return .targetHasNoVideo }
        let diffs = differences(clip, target: target)
        return diffs.isEmpty ? .smartRender : .reEncode(diffs)
    }

    /// A nil/empty property value shown as an em dash so an "unspecified → bt709" difference
    /// still reads clearly.
    private static func display(_ value: String?) -> String {
        (value?.isEmpty == false) ? value! : "—"
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
        scanDirection(output.fieldOrder) == scanDirection(target.fieldOrder) &&
        output.sampleAspectRatio == target.sampleAspectRatio &&
        colorSatisfies(output.colorPrimaries, target: target.colorPrimaries) &&
        colorSatisfies(output.colorTransfer, target: target.colorTransfer) &&
        colorSatisfies(output.colorSpace, target: target.colorSpace) &&
        colorSatisfies(output.colorRange, target: target.colorRange)
    }

    /// A target color field that is unspecified (nil) imposes no requirement on the conformed
    /// output; a specified one must match exactly.
    static func colorSatisfies(_ output: String?, target: String?) -> Bool {
        target == nil || output == target
    }

    /// Canonicalises an ffprobe `field_order` for display and conform targeting: a missing,
    /// empty, or "unknown" value means progressive (a clean progressive HEVC stream often
    /// reports no field order at all, so the target clip would otherwise be unmatchable even
    /// by a copy of itself — ADR-0011). Interlaced values (`tt`/`bb`/`tb`/`bt`) are returned
    /// unchanged. Comparisons go through `scanDirection`, not this.
    static func normalizedFieldOrder(_ value: String?) -> String {
        switch value {
        case nil, "", "unknown", "progressive": return "progressive"
        default: return value!
        }
    }

    /// The scan direction an ffprobe `field_order` spells (issue #119, ADR-0005): `tt` and `tb`
    /// are both top-field-first, `bb` and `bt` both bottom-field-first, everything else
    /// progressive. This is the value every scan comparison uses.
    ///
    /// The second letter (the *display* order) is not a property of the coded stream but of
    /// where the probe read it: ffmpeg 9's encoder front end tags every interlaced encode
    /// `tb`/`bt`, and only Matroska stores that tag, so the same libx264 bitstream probes `tb`
    /// in an encoder-written MKV and `tt` in MPEG-TS, MP4, or an MKV it was stream-copied
    /// into. Comparing the spelling made a `tt` target unreachable by any conform (ADR-0009
    /// probe trap). A genuine difference — progressive against interlaced, or top-first against
    /// bottom-first — still fails.
    static func scanDirection(_ value: String?) -> String {
        switch normalizedFieldOrder(value) {
        case "tt", "tb": return "tff"
        case "bb", "bt": return "bff"
        default: return "progressive"
        }
    }
}
