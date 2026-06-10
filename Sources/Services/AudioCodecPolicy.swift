import Foundation

/// The audio codec policy (ADR-0010 / ADR-0014): which codec the rebuilt audio encodes
/// to for a given target clip and container, the ffmpeg encoder and file extensions
/// that follow from it, and which output audio tracks an export carries. Pure decisions
/// only — the ffmpeg invocations that act on them live in the export engines.
enum AudioCodecPolicy {
    /// Fallback audio codec when the target clip's codec can't be used (ADR-0010): AAC is
    /// broadly supported across the TS/MKV/MP4 containers and audibly transparent at the
    /// 192 kbps the export engine encodes at.
    static let fallbackAudioCodec = "aac"

    /// One output audio track's spec (ADR-0014): every leg of its concat chain is
    /// conformed to this rate/layout (silence is generated in it), and the tags are
    /// written on the output stream (titles only survive in MKV — container reality).
    struct OutputAudioTrack: Equatable {
        var sampleRate: Int
        var channels: Int
        var language: String? = nil
        var title: String? = nil
    }

    /// The audio codec the export will actually encode to, and whether it had to fall back.
    /// The rebuilt audio conforms to the target clip's codec (ADR-0010); `encoder` is the
    /// ffmpeg encoder name for it, which differs from the ffprobe `codec` for some codecs.
    struct AudioEncodeChoice: Equatable {
        var codec: String     // ffprobe codec_name being targeted, e.g. "mp2"
        var encoder: String   // ffmpeg encoder, e.g. "mp2", "libmp3lame", "aac"
        var fellBack: Bool     // true when the target codec was declined for AAC (warn the user)
    }

    /// Resolves the rebuilt audio's codec (ADR-0010): the target clip's audio codec when it
    /// maps to an encoder and sits cleanly in the chosen container, else AAC. `fellBack` is
    /// true only when a real target codec was *declined* (container-incompatible or
    /// unmappable) — not when the target is already AAC, and not when there is no target
    /// audio (then AAC is just the default, no warning).
    static func resolveAudioCodec(targetCodec: String?, container: Container) -> AudioEncodeChoice {
        guard let target = targetCodec else {
            return AudioEncodeChoice(codec: fallbackAudioCodec, encoder: fallbackAudioCodec, fellBack: false)
        }
        if let encoder = audioEncoder(for: target), audioCodecFitsContainer(target, container) {
            return AudioEncodeChoice(codec: target, encoder: encoder, fellBack: false)
        }
        return AudioEncodeChoice(codec: fallbackAudioCodec, encoder: fallbackAudioCodec, fellBack: true)
    }

    /// Resolves the audio codec for an **audio-only** export (`OutputType.audioOnly`). Unlike
    /// the video+audio case there is no video container to fit — the audio is written to its
    /// own elementary file (see `audioFileExtension`) — so the only constraint is having an
    /// encoder for the target codec, else AAC. `fellBack` is true only when a real target
    /// codec was unmappable.
    static func resolveAudioOnlyCodec(targetCodec: String?) -> AudioEncodeChoice {
        if let target = targetCodec, let encoder = audioEncoder(for: target) {
            return AudioEncodeChoice(codec: target, encoder: encoder, fellBack: false)
        }
        return AudioEncodeChoice(codec: fallbackAudioCodec, encoder: fallbackAudioCodec,
                                 fellBack: targetCodec != nil)
    }

    /// The file extension for an audio-only export, by the ffmpeg encoder being used: each
    /// codec gets its natural elementary-stream container (verified in the shell). The chosen
    /// video Container (TS/MKV/MP4) does not apply to an audio-only output.
    static func audioFileExtension(forEncoder encoder: String) -> String {
        switch encoder {
        case "mp2": return "mp2"
        case "ac3": return "ac3"
        case "libmp3lame": return "mp3"
        default: return "m4a"   // aac (and any future fallback)
        }
    }

    /// The output file extension for a whole export: the audio-elementary extension for an
    /// audio-only output, otherwise the chosen video container's extension.
    static func outputExtension(type: OutputType, container: Container, audioEncoder: String) -> String {
        type == .audioOnly ? audioFileExtension(forEncoder: audioEncoder) : container.fileExtension
    }

    /// The ffmpeg encoder for an ffprobe audio `codec_name`, or `nil` if we don't carry one
    /// (then the export falls back to AAC). Covers the broadcast codecs seen in this domain.
    static func audioEncoder(for codec: String) -> String? {
        switch codec {
        case "aac": return "aac"
        case "mp2": return "mp2"
        case "ac3": return "ac3"
        case "mp3": return "libmp3lame"
        default: return nil
        }
    }

    /// Whether an audio codec sits cleanly in a container. Verified in the shell: the only
    /// awkward combo among the supported codecs is mp2 in MP4 (the MP4 muxer relabels it
    /// mp3); TS and MKV carry mp2/aac/ac3/mp3, and MP4 carries aac/ac3/mp3.
    static func audioCodecFitsContainer(_ codec: String, _ container: Container) -> Bool {
        !(container == .mp4 && codec == "mp2")
    }

    /// The output audio tracks an export will carry (ADR-0014): as many as the richest
    /// clip's selected sources, each track's format/tags taken from the target clip's
    /// corresponding track when it has one, else from the first clip in timeline order
    /// that does.
    static func resolveOutputTracks(target: Clip?, clips: [Clip]) -> [OutputAudioTrack] {
        let count = clips.map { $0.resolvedAudioSelections.count }.max() ?? 0
        let donors = (target.map { [$0] } ?? []) + clips
        return (0..<count).map { t in
            let donor = donors.lazy.compactMap { clip -> AudioProperties? in
                let tracks = clip.effectiveAudioTracks
                return t < tracks.count ? tracks[t] : nil
            }.first
            return OutputAudioTrack(sampleRate: donor?.sampleRate ?? 48000,
                                    channels: donor?.channels ?? 2,
                                    language: donor?.language,
                                    title: donor?.title)
        }
    }
}
