import Foundation

enum OutputMode: String, Codable, CaseIterable, Identifiable {
    case connect
    case separate

    var id: String { rawValue }
    var title: String {
        switch self {
        case .connect: return "Connect into one"
        case .separate: return "Export separately"
        }
    }
}

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

enum SeparateRendering: String, Codable, CaseIterable, Identifiable {
    case conformToTarget
    case cutOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .conformToTarget: return "Conform to target"
        case .cutOnly: return "Cut only"
        }
    }
}

struct OutputSettings: Codable, Equatable {
    var mode: OutputMode = .connect
    var type: OutputType = .videoAndAudio
    var container: Container = .mkv
    var rendering: SeparateRendering = .conformToTarget
    var conformCrf: Int? = nil

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(OutputMode.self, forKey: .mode) ?? .connect
        type = try c.decodeIfPresent(OutputType.self, forKey: .type) ?? .videoAndAudio
        container = try c.decodeIfPresent(Container.self, forKey: .container) ?? .mkv
        rendering = try c.decodeIfPresent(SeparateRendering.self, forKey: .rendering) ?? .conformToTarget
        conformCrf = try c.decodeIfPresent(Int.self, forKey: .conformCrf)
    }
}
