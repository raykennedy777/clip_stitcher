import Foundation

/// Which source feeds one slot in a clip's audio track list (ADR-0014).
enum AudioTrackSelection: Codable, Equatable {
    /// The clip's own Nth audio stream (0-based).
    case stream(Int)
    /// One audio stream of an external file (audio-only or another video), aligned
    /// file start = video-file start (ADR-0014). `streamIndex` picks among the file's
    /// audio streams; `tracks` (all of them) and `duration` are probed when the file
    /// is picked, for stream naming, output formats, and the length-mismatch notice.
    case external(bookmark: Data, name: String, streamIndex: Int, tracks: [AudioProperties]?, duration: Double?)
}

/// How a slot's source channels are mixed into its output track (ADR-0019): never the
/// track's channel layout — only what is mixed into it. Semantics are relative to the
/// source's normal stereo listening experience: Stereo is a deliberate surround→stereo
/// fold-down, Left/Right only take one side of that fold-down heard alone, Mono folds
/// everything to one signal.
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

    /// ADR-0019's no-op table: Stereo changes nothing for a mono/stereo source;
    /// Left/Right/Mono change nothing for a mono source; Original is the identity by
    /// definition. An unknown channel count (an unprobed external file, a missing
    /// stream — the slot plays silence) counts as no-op too: there is no content to
    /// judge a mix against. No-op options are disabled in the picker and produce no
    /// filter, so the leg stays byte-identical to today's.
    func isNoOp(sourceChannels: Int?) -> Bool {
        guard let channels = sourceChannels, channels > 0 else { return true }
        switch self {
        case .original: return true
        case .stereo: return channels <= 2
        case .leftOnly, .rightOnly, .mono: return channels <= 1
        }
    }
}

/// One slot in a clip's audio track list: which source feeds it, plus how that source's
/// channels are mixed into the output track (ADR-0019). Saves made before the channel
/// mix stored the bare `AudioTrackSelection`; decoding accepts both shapes, so old
/// projects load with every track at Original.
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
            // The pre-mix shape: the slot *is* the selection enum's own payload.
            self.selection = try AudioTrackSelection(from: decoder)
            self.mix = .original
        }
    }

    /// Case-shaped factories so a slot list reads like the selection list it replaced.
    static func stream(_ i: Int) -> AudioTrackSlot { AudioTrackSlot(selection: .stream(i)) }
    static func external(bookmark: Data, name: String, streamIndex: Int,
                         tracks: [AudioProperties]?, duration: Double?) -> AudioTrackSlot {
        AudioTrackSlot(selection: .external(bookmark: bookmark, name: name, streamIndex: streamIndex,
                                            tracks: tracks, duration: duration))
    }
}

/// One imported source file plus its selected in/out range and probed properties.
/// Occupies one row in the timeline.
struct Clip: Codable, Identifiable, Equatable {
    var id: UUID = UUID()

    /// Bookmark to the source file on disk. Resolved to a URL at runtime; the media
    /// itself is never stored in the project.
    var bookmark: Data

    var displayName: String

    // Probed properties (filled asynchronously after import).
    var video: VideoProperties? = nil
    /// The first audio stream — legacy single-track field, kept so old saves decode
    /// unchanged. New code reads `allAudioTracks` (ADR-0014).
    var audio: AudioProperties? = nil
    /// Every probed audio stream in container order; nil on saves made before
    /// multi-track audio (then `audio` is all we know).
    var audioTracks: [AudioProperties]? = nil
    var duration: Double? = nil
    var frameCount: Int? = nil

    /// Set at import when the source stores each *field* as its own packet (PAFF —
    /// two packets per displayed frame, issue #46). The frame index counts packets
    /// as frames (ADR-0006), so frame numbers, cut points, and count verifications
    /// are all off by 2× on such a file — the row warns that frame-accurate cutting
    /// and export aren't supported for it yet. `nil` on saves made before the check
    /// (and while probing).
    var fieldCoded: Bool? = nil

    /// The source's damage zones found at import (issue #45), in source seconds from
    /// the container start, sorted. Empty = scanned clean; `nil` = not scanned (a
    /// save made before damage detection, or a clip still importing). A clip with no
    /// zones behaves exactly as before detection existed.
    var damageZones: [DamageZone]? = nil

    /// The clip's audio tracks regardless of save vintage: the probed list when
    /// present, else the legacy single track, else none.
    var allAudioTracks: [AudioProperties] {
        audioTracks ?? audio.map { [$0] } ?? []
    }

    /// The clip's audio track slots; nil means the default — all of the clip's own
    /// streams in container order, each at the Original mix. Decodes as nil from saves
    /// made before ADR-0014. (Named for the save key: pre-mix saves stored the bare
    /// selection enum, which `AudioTrackSlot` still decodes.)
    var audioSelections: [AudioTrackSlot]? = nil

    /// The slot monitored in the cut-editor's audio dropdown. Stored now; it becomes
    /// audible when the cut-editor gains audio playback.
    var monitoredAudioTrack: Int? = nil

    /// The audio track slots with the default applied.
    var resolvedAudioSelections: [AudioTrackSlot] {
        audioSelections ?? allAudioTracks.indices.map { .stream($0) }
    }

    /// The probed properties feeding each slot — nil where unknown (an out-of-range
    /// stream or an unprobed external file). Drives track naming and output formats.
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

    /// The name shown for slot `t` (0-based): the feeding track's metadata name,
    /// or the "Track N" fallback (ADR-0014).
    func audioTrackName(_ t: Int) -> String {
        let tracks = effectiveAudioTracks
        guard t < tracks.count, let properties = tracks[t] else { return "Track \(t + 1)" }
        return properties.displayName(trackNumber: t + 1)
    }

    /// How much longer (+) or shorter (−) an external audio file is than the clip's
    /// video, in seconds — nil when the slot isn't external or a duration is unknown.
    /// A gap of 1 s or more is surfaced to the user; either way the export pads with
    /// silence or trims, never errors (ADR-0014).
    func externalAudioMismatch(slot: Int) -> Double? {
        let selections = resolvedAudioSelections
        guard slot < selections.count,
              case .external(_, _, _, _, let externalDuration?) = selections[slot].selection,
              let videoDuration = duration else { return nil }
        return externalDuration - videoDuration
    }

    // Selection range, in source frame numbers. nil means the clip boundary
    // (0 for in, last frame for out). Set later in the cut-editor.
    var inPoint: Int? = nil
    var outPoint: Int? = nil
}
