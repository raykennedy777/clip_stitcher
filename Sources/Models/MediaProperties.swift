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

/// Audio stream properties relevant to target-clip matching (see ADR-0005).
struct AudioProperties: Codable, Equatable, Sendable {
    var codec: String
    var sampleRate: Int
    var channels: Int
    var channelLayout: String?
}
