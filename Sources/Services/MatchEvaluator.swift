import Foundation

/// Decides whether a clip can be smart-rendered against the target clip, applying
/// the strict matching rule from ADR-0005. Any difference in the compared
/// properties means the clip must be fully re-encoded (conformed) to the target.
enum MatchEvaluator {
    static func matches(_ clip: Clip, target: Clip) -> Bool {
        guard let cv = clip.video, let tv = target.video else { return false }

        let videoMatches =
            cv.codec == tv.codec &&
            cv.profile == tv.profile &&
            cv.level == tv.level &&
            cv.width == tv.width &&
            cv.height == tv.height &&
            cv.frameRate == tv.frameRate &&
            cv.pixelFormat == tv.pixelFormat &&
            cv.fieldOrder == tv.fieldOrder &&
            cv.sampleAspectRatio == tv.sampleAspectRatio &&
            cv.colorPrimaries == tv.colorPrimaries &&
            cv.colorTransfer == tv.colorTransfer &&
            cv.colorRange == tv.colorRange

        let audioMatches: Bool
        switch (clip.audio, target.audio) {
        case let (a?, b?):
            audioMatches = a.codec == b.codec && a.sampleRate == b.sampleRate && a.channels == b.channels
        case (nil, nil):
            audioMatches = true
        default:
            audioMatches = false
        }

        return videoMatches && audioMatches
    }
}
