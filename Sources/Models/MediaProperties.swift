import Foundation

/// Video stream properties relevant to target-clip matching (see ADR-0005).
struct VideoProperties: Codable, Equatable, Sendable {
    var codec: String
    var profile: String?
    var level: String?
    var width: Int
    var height: Int
    /// Average frame rate as reported by ffprobe, e.g. "25/1".
    var frameRate: String
    var pixelFormat: String
    /// progressive, tt (top-first), bb (bottom-first), etc.
    var fieldOrder: String?
    /// Sample (pixel) aspect ratio, e.g. "1:1".
    var sampleAspectRatio: String?
    var colorPrimaries: String?
    var colorTransfer: String?
    var colorRange: String?
}

/// One probed audio stream of a source file (ADR-0014). `language`/`title` come from
/// container tags — full names generally only exist on MKV sources; TS and MP4 carry
/// language at best. Both decode as nil from saves made before multi-track audio.
struct AudioProperties: Codable, Equatable, Sendable {
    var codec: String
    var sampleRate: Int
    var channels: Int
    var channelLayout: String?
    /// ISO language tag from the container (e.g. "eng"), if any.
    var language: String? = nil
    /// Human-readable track title from the container (e.g. "World Feed"), if any.
    var title: String? = nil

    /// The name shown for this track (ADR-0014): the container title when present,
    /// else "Track N"; the language tag is always appended when present.
    /// e.g. "World Feed (eng)", "Natural Sounds", "Track 2 (spa)", "Track 3".
    func displayName(trackNumber: Int) -> String {
        let base = title?.isEmpty == false ? title! : "Track \(trackNumber)"
        if let language, !language.isEmpty, language != "und" {
            return "\(base) (\(language))"
        }
        return base
    }
}
