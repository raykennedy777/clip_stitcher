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

/// How separate mode renders each clip (ADR-0018). A sub-setting of `.separate` —
/// connect mode always conforms, because joining requires uniform properties.
enum SeparateRendering: String, Codable, CaseIterable, Identifiable {
    case conformToTarget   // today's verdict: matching clips smart-render, others conform
    case cutOnly           // every clip smart-renders against itself; the target plays no role

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
    var container: Container = .mp4
    var rendering: SeparateRendering = .conformToTarget

    init() {}

    /// Saves made before a field existed decode to its default instead of failing
    /// the whole project file (`rendering` arrived with ADR-0018).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(OutputMode.self, forKey: .mode) ?? .connect
        type = try c.decodeIfPresent(OutputType.self, forKey: .type) ?? .videoAndAudio
        container = try c.decodeIfPresent(Container.self, forKey: .container) ?? .mp4
        rendering = try c.decodeIfPresent(SeparateRendering.self, forKey: .rendering) ?? .conformToTarget
    }
}
