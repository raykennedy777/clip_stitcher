import Foundation

struct VideoProperties: Codable, Equatable, Sendable {
    var codec: String
    var profile: String?
    var level: String?
    var width: Int
    var height: Int
    var frameRate: String
    var pixelFormat: String
    var fieldOrder: String?
    var sampleAspectRatio: String?
    var colorPrimaries: String?
    var colorTransfer: String?
    var colorSpace: String? = nil
    var colorRange: String?
    var reorderDepth: Int? = nil
    var bitrate: Int? = nil
}

struct AudioProperties: Codable, Equatable, Sendable {
    var codec: String
    var sampleRate: Int
    var channels: Int
    var channelLayout: String?
    var language: String? = nil
    var title: String? = nil
    var bitrate: Int? = nil

    func displayName(trackNumber: Int) -> String {
        let base = title?.isEmpty == false ? title! : "Track \(trackNumber)"
        if let language, !language.isEmpty, language != "und" {
            return "\(base) (\(language))"
        }
        return base
    }
}
