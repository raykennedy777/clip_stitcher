import Foundation

/// How the output is assembled.
enum OutputMode: String, Codable, CaseIterable, Identifiable {
    case connect      // Connect all clips into one file
    case separate     // Export each clip as its own file

    var id: String { rawValue }
    var title: String {
        switch self {
        case .connect: return "Connect into one"
        case .separate: return "Export separately"
        }
    }
}

/// Which streams to include in the output.
enum OutputType: String, Codable, CaseIterable, Identifiable {
    case videoAndAudio
    case videoOnly
    case audioOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .videoAndAudio: return "Video + Audio"
        case .videoOnly: return "Video only"
        case .audioOnly: return "Audio only"
        }
    }
}

/// Output container format.
enum Container: String, Codable, CaseIterable, Identifiable {
    case ts
    case mkv
    case mp4

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ts: return "TS (Transport Stream)"
        case .mkv: return "MKV"
        case .mp4: return "MP4"
        }
    }
    var fileExtension: String { rawValue }
}

struct OutputSettings: Codable, Equatable {
    var mode: OutputMode = .connect
    var type: OutputType = .videoAndAudio
    var container: Container = .mp4
}
