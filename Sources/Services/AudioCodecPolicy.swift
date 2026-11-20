import Foundation

enum AudioCodecPolicy {
    static let fallbackAudioCodec = "aac"

    struct OutputAudioTrack: Equatable {
        var sampleRate: Int
        var channels: Int
        var language: String? = nil
        var title: String? = nil
        var encoder: String? = nil
    }

    struct AudioEncodeChoice: Equatable {
        var codec: String
        var encoder: String
        var fellBack: Bool
    }

    static func resolveAudioCodec(targetCodec: String?, container: Container) -> AudioEncodeChoice {
        guard let target = targetCodec else {
            return AudioEncodeChoice(codec: fallbackAudioCodec, encoder: fallbackAudioCodec, fellBack: false)
        }
        if let encoder = audioEncoder(for: target), audioCodecFitsContainer(target, container) {
            return AudioEncodeChoice(codec: target, encoder: encoder, fellBack: false)
        }
        return AudioEncodeChoice(codec: fallbackAudioCodec, encoder: fallbackAudioCodec, fellBack: true)
    }

    static func resolveAudioOnlyCodec(targetCodec: String?) -> AudioEncodeChoice {
        if let target = targetCodec, let encoder = audioEncoder(for: target) {
            return AudioEncodeChoice(codec: target, encoder: encoder, fellBack: false)
        }
        return AudioEncodeChoice(codec: fallbackAudioCodec, encoder: fallbackAudioCodec,
                                 fellBack: targetCodec != nil)
    }

    static func audioFileExtension(forEncoder encoder: String) -> String {
        switch encoder {
        case "mp2": return "mp2"
        case "ac3": return "ac3"
        case "libmp3lame": return "mp3"
        default: return "m4a"
        }
    }

    static func outputExtension(type: OutputType, container: Container, audioEncoder: String) -> String {
        type == .audioOnly ? audioFileExtension(forEncoder: audioEncoder) : container.fileExtension
    }

    static func audioEncoder(for codec: String) -> String? {
        switch codec {
        case "aac": return "aac"
        case "mp2": return "mp2"
        case "ac3": return "ac3"
        case "mp3": return "libmp3lame"
        default: return nil
        }
    }

    static func audioCodecFitsContainer(_ codec: String, _ container: Container) -> Bool {
        !(container == .mp4 && codec == "mp2")
    }
}
