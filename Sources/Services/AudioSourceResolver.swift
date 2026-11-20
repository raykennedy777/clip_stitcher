import Foundation

enum AudioSourceResolver {
    enum MissingExternalPolicy {
        case degradeToSilence
        case throwError
    }

    struct MissingExternalFile: Error, Equatable {
        var name: String
        var slot: Int
    }

    static func resolveSources(
        for clip: Clip, missingExternal policy: MissingExternalPolicy
    ) throws -> [ExportEngine.AudioSource?] {
        try clip.resolvedAudioSelections.enumerated().map { slot, trackSlot in
            switch trackSlot.selection {
            case .stream(let s):
                return s < clip.allAudioTracks.count ? .stream(s) : nil
            case .external(let bookmark, let name, let streamIndex, _, _):
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
                      FileManager.default.fileExists(atPath: url.path) else {
                    switch policy {
                    case .degradeToSilence: return nil
                    case .throwError: throw MissingExternalFile(name: name, slot: slot)
                    }
                }
                return .external(url, stream: streamIndex)
            }
        }
    }

    static func resolveMixFilters(for clip: Clip) -> [String?] {
        zip(clip.resolvedAudioSelections, clip.effectiveAudioTracks).map { slot, properties in
            ConformEngine.mixFilter(slot.mix, sourceChannels: properties?.channels)
        }
    }

    static func resolveOwnTracks(clip: Clip, type: OutputType, container: Container)
        -> (tracks: [AudioCodecPolicy.OutputAudioTrack], fallbacks: [(slot: Int, codec: String)]) {
        var fallbacks: [(slot: Int, codec: String)] = []
        var tracks = clip.effectiveAudioTracks.enumerated().map { t, props -> AudioCodecPolicy.OutputAudioTrack in
            let choice = type == .audioOnly
                ? AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: props?.codec)
                : AudioCodecPolicy.resolveAudioCodec(targetCodec: props?.codec, container: container)
            if choice.fellBack, let wanted = props?.codec {
                fallbacks.append((slot: t, codec: wanted))
            }
            return AudioCodecPolicy.OutputAudioTrack(
                sampleRate: props?.sampleRate ?? 48000, channels: props?.channels ?? 2,
                language: props?.language, title: props?.title, encoder: choice.encoder)
        }
        if type == .audioOnly {
            tracks = Array(tracks.prefix(1))
            fallbacks = fallbacks.filter { $0.slot == 0 }
        }
        return (tracks, fallbacks)
    }

    static func resolveOutputTracks(target: Clip?, clips: [Clip]) -> [AudioCodecPolicy.OutputAudioTrack] {
        let count = clips.map { $0.resolvedAudioSelections.count }.max() ?? 0
        let donors = (target.map { [$0] } ?? []) + clips
        return (0..<count).map { t in
            let donor = donors.lazy.compactMap { clip -> AudioProperties? in
                let tracks = clip.effectiveAudioTracks
                return t < tracks.count ? tracks[t] : nil
            }.first
            return AudioCodecPolicy.OutputAudioTrack(sampleRate: donor?.sampleRate ?? 48000,
                                                     channels: donor?.channels ?? 2,
                                                     language: donor?.language,
                                                     title: donor?.title)
        }
    }
}
