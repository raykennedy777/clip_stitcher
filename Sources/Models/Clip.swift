import Foundation

enum AudioTrackSelection: Codable, Equatable {
    case stream(Int)
    case external(bookmark: Data, name: String, streamIndex: Int, tracks: [AudioProperties]?, duration: Double?)
}

enum ChannelMix: String, Codable, CaseIterable, Equatable {
    case original
    case stereo
    case leftOnly
    case rightOnly
    case mono

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .stereo: return "Stereo"
        case .leftOnly: return "Left only"
        case .rightOnly: return "Right only"
        case .mono: return "Mono"
        }
    }

    func isNoOp(sourceChannels: Int?) -> Bool {
        guard let channels = sourceChannels, channels > 0 else { return true }
        switch self {
        case .original: return true
        case .stereo: return channels <= 2
        case .leftOnly, .rightOnly, .mono: return channels <= 1
        }
    }
}

struct AudioTrackSlot: Codable, Equatable {
    var selection: AudioTrackSelection
    var mix: ChannelMix

    init(selection: AudioTrackSelection, mix: ChannelMix = .original) {
        self.selection = selection
        self.mix = mix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let selection = try container.decodeIfPresent(AudioTrackSelection.self, forKey: .selection) {
            self.selection = selection
            self.mix = try container.decodeIfPresent(ChannelMix.self, forKey: .mix) ?? .original
        } else {
            self.selection = try AudioTrackSelection(from: decoder)
            self.mix = .original
        }
    }

    static func stream(_ i: Int) -> AudioTrackSlot { AudioTrackSlot(selection: .stream(i)) }
    static func external(bookmark: Data, name: String, streamIndex: Int,
                         tracks: [AudioProperties]?, duration: Double?) -> AudioTrackSlot {
        AudioTrackSlot(selection: .external(bookmark: bookmark, name: name, streamIndex: streamIndex,
                                            tracks: tracks, duration: duration))
    }
}

struct Clip: Codable, Identifiable, Equatable {
    var id: UUID = UUID()

    var bookmark: Data

    var displayName: String

    var video: VideoProperties? = nil
    var audio: AudioProperties? = nil
    var audioTracks: [AudioProperties]? = nil
    var duration: Double? = nil
    var frameCount: Int? = nil

    var fieldCoded: Bool? = nil

    var damageZones: [DamageZone]? = nil

    var allAudioTracks: [AudioProperties] {
        audioTracks ?? audio.map { [$0] } ?? []
    }

    var audioSelections: [AudioTrackSlot]? = nil

    var monitoredAudioTrack: Int? = nil

    var resolvedAudioSelections: [AudioTrackSlot] {
        audioSelections ?? allAudioTracks.indices.map { .stream($0) }
    }

    var effectiveAudioTracks: [AudioProperties?] {
        resolvedAudioSelections.map { slot in
            switch slot.selection {
            case .stream(let i):
                return i < allAudioTracks.count ? allAudioTracks[i] : nil
            case .external(_, _, let streamIndex, let tracks, _):
                guard let tracks, streamIndex < tracks.count else { return nil }
                return tracks[streamIndex]
            }
        }
    }

    func audioTrackName(_ t: Int) -> String {
        let tracks = effectiveAudioTracks
        guard t < tracks.count, let properties = tracks[t] else { return "Track \(t + 1)" }
        return properties.displayName(trackNumber: t + 1)
    }

    func externalAudioMismatch(slot: Int) -> Double? {
        let selections = resolvedAudioSelections
        guard slot < selections.count,
              case .external(_, _, _, _, let externalDuration?) = selections[slot].selection,
              let videoDuration = duration else { return nil }
        return externalDuration - videoDuration
    }

    var inPoint: Int? = nil
    var outPoint: Int? = nil
}
