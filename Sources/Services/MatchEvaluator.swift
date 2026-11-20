import Foundation

enum MatchEvaluator {
    static func matches(_ clip: Clip, target: Clip) -> Bool {
        guard let cv = clip.video, let tv = target.video else { return false }

        return videoMatches(cv, tv)
    }

    static func videoMatches(_ cv: VideoProperties, _ tv: VideoProperties) -> Bool {
        videoDifferences(cv, tv).isEmpty
    }

    struct VideoDifference: Equatable {
        let label: String
        let clipValue: String
        let targetValue: String
    }

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

    static func differences(_ clip: Clip, target: Clip) -> [VideoDifference] {
        guard let cv = clip.video, let tv = target.video else { return [] }
        return videoDifferences(cv, tv)
    }

    enum MatchVerdict: Equatable {
        case isTarget
        case noTarget
        case clipHasNoVideo
        case targetHasNoVideo
        case smartRender
        case reEncode([VideoDifference])

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

    private static func display(_ value: String?) -> String {
        (value?.isEmpty == false) ? value! : "—"
    }

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

    static func colorSatisfies(_ output: String?, target: String?) -> Bool {
        target == nil || output == target
    }

    static func normalizedFieldOrder(_ value: String?) -> String {
        switch value {
        case nil, "", "unknown", "progressive": return "progressive"
        default: return value!
        }
    }

    static func scanDirection(_ value: String?) -> String {
        switch normalizedFieldOrder(value) {
        case "tt", "tb": return "tff"
        case "bb", "bt": return "bff"
        default: return "progressive"
        }
    }
}
