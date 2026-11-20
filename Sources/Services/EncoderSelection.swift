import Foundation

enum EncoderSelection {
    static func encoder(for codec: String?) -> String {
        switch codec {
        case "hevc": return "libx265"
        case "mpeg2video": return "mpeg2video"
        default: return "libx264"
        }
    }

    static func profileCodec(for codec: String?) -> String {
        switch codec {
        case "hevc", "mpeg2video": return codec!
        default: return "h264"
        }
    }

    static func encoderProfile(_ profile: String?, codec: String) -> String? {
        guard let profile else { return nil }
        switch codec {
        case "h264":
            return [
                "Constrained Baseline": "baseline", "Baseline": "baseline", "Main": "main",
                "High": "high", "High 10": "high10", "High 4:2:2": "high422",
                "High 4:4:4 Predictive": "high444",
            ][profile]
        case "hevc":
            return [
                "Main": "main", "Main 10": "main10", "Main 12": "main12",
                "Main Still Picture": "mainstillpicture",
            ][profile]
        case "mpeg2video":
            return [
                "Simple": "simple", "Main": "main", "High": "high", "4:2:2": "422",
            ][profile]
        default:
            return nil
        }
    }

    static let deepestEncodableReorderDepth = 2

    static func reorderDepthParams(depth: Int, forCodec codec: String?) -> [String] {
        guard codec != "mpeg2video", depth <= 1 else { return [] }
        return ["b-pyramid=0"]
    }

    static func encoderParams(_ entries: [String], forCodec codec: String?) -> [String] {
        withEncoderParams(entries, in: [], forCodec: codec)
    }

    // ADR-0026
    static func withEncoderParams(_ entries: [String], in args: [String], forCodec codec: String?) -> [String] {
        guard !entries.isEmpty, codec != "mpeg2video" else { return args }
        let flag = codec == "hevc" ? "-x265-params" : "-x264-params"
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else {
            return args + [flag, entries.joined(separator: ":")]
        }
        var merged = args
        merged[i + 1] = ([args[i + 1]] + entries).joined(separator: ":")
        return merged
    }

    static func h264Level(_ level: String?) -> String? {
        guard let n = level.flatMap(Int.init) else { return nil }
        return "\(n / 10).\(n % 10)"
    }

    static func hevcLevel(_ level: String?) -> String? {
        guard let n = level.flatMap(Int.init) else { return nil }
        return "\(n / 30).\((n % 30) / 3)"
    }
}
