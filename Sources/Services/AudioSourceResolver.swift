import Foundation

/// Resolves a clip's audio track selections into the concrete sources that feed the
/// audio rebuild (ADR-0014) — one source per output track: the clip's own Nth stream,
/// an external file's chosen stream resolved to a URL, or `nil` for silence. The one
/// resolver behind both the export and the output preview's playback; the only
/// difference between them — what to do about an external file that can't be reached —
/// is an explicit policy parameter here, not a fork.
///
/// Output-track derivation (how many tracks the output carries and each track's
/// format/tags) lives here too, so the count/naming logic has one home.
enum AudioSourceResolver {
    /// What to do when a slot's external audio file can't be reached (the bookmark no
    /// longer resolves, or the file is gone).
    enum MissingExternalPolicy {
        /// The slot degrades to silence — best-effort playback (the output preview).
        case degradeToSilence
        /// Throw `MissingExternalFile` — the export refuses to silently drop a track
        /// the user selected.
        case throwError
    }

    /// A slot's external audio file could not be reached under `.throwError`.
    struct MissingExternalFile: Error, Equatable {
        /// The display name the file was picked under.
        var name: String
        /// The 0-based slot (output track) it feeds.
        var slot: Int
    }

    /// The concrete source feeding each of the clip's audio track slots, in slot
    /// order: `.stream(n)` for the clip's own nth audio stream, `.external` with the
    /// bookmark resolved to a URL, or `nil` for silence — an own-stream selection past
    /// the clip's streams is silence under either policy (the slot exists because a
    /// richer clip has it; ADR-0014).
    static func resolveSources(
        for clip: Clip, missingExternal policy: MissingExternalPolicy
    ) throws -> [ExportEngine.AudioSource?] {
        try clip.resolvedAudioSelections.enumerated().map { slot, selection in
            switch selection {
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

    /// The output audio tracks an export will carry (ADR-0014): as many as the richest
    /// clip's selected sources, each track's format/tags taken from the target clip's
    /// corresponding track when it has one, else from the first clip in timeline order
    /// that does.
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
