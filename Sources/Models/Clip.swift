import Foundation

/// One slot in a clip's audio track list (ADR-0014): which source feeds it.
enum AudioTrackSelection: Codable, Equatable {
    /// The clip's own Nth audio stream (0-based).
    case stream(Int)
    /// One audio stream of an external file (audio-only or another video), aligned
    /// file start = video-file start (ADR-0014). `streamIndex` picks among the file's
    /// audio streams; `tracks` (all of them) and `duration` are probed when the file
    /// is picked, for stream naming, output formats, and the length-mismatch notice.
    case external(bookmark: Data, name: String, streamIndex: Int, tracks: [AudioProperties]?, duration: Double?)
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

    /// The clip's audio tracks regardless of save vintage: the probed list when
    /// present, else the legacy single track, else none.
    var allAudioTracks: [AudioProperties] {
        audioTracks ?? audio.map { [$0] } ?? []
    }

    /// The clip's audio track slots; nil means the default — all of the clip's own
    /// streams in container order. Decodes as nil from saves made before ADR-0014.
    var audioSelections: [AudioTrackSelection]? = nil

    /// The slot monitored in the cut-editor's audio dropdown. Stored now; it becomes
    /// audible when the cut-editor gains audio playback.
    var monitoredAudioTrack: Int? = nil

    /// The audio track slots with the default applied.
    var resolvedAudioSelections: [AudioTrackSelection] {
        audioSelections ?? allAudioTracks.indices.map { .stream($0) }
    }

    /// The probed properties feeding each slot — nil where unknown (an out-of-range
    /// stream or an unprobed external file). Drives track naming and output formats.
    var effectiveAudioTracks: [AudioProperties?] {
        resolvedAudioSelections.map { selection in
            switch selection {
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
              case .external(_, _, _, _, let externalDuration?) = selections[slot],
              let videoDuration = duration else { return nil }
        return externalDuration - videoDuration
    }

    // Selection range, in source frame numbers. nil means the clip boundary
    // (0 for in, last frame for out). Set later in the cut-editor.
    var inPoint: Int? = nil
    var outPoint: Int? = nil
}
