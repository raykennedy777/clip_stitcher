import Foundation

/// The audio side of the output preview (issue #8): for each (output track × timeline
/// segment) it resolves what the export's audio rebuild would put there (ADR-0014) —
/// the clip's selected source for that track, an external file's chosen stream, or
/// silence — plus the seek/duration math to join a leg mid-stream. Pure (no decoding,
/// no file access) so the leg resolution and timing can be unit-tested; the playback
/// side hands the result to `AudioStreamPlayer`.
struct PreviewAudioPlan {
    /// What one leg plays.
    enum LegSource: Equatable {
        /// One audio stream of a file — the clip's own or an external one, already
        /// resolved to a URL. The same seek applies either way: an external file is
        /// aligned file start = video-file start (ADR-0014), and `-ss` into it is
        /// file-start-relative too (ADR-0015).
        case stream(URL, streamIndex: Int)
        /// A silence-filled span: the clip has no source for this track. Real
        /// silence — the playhead keeps moving, matching the export.
        case silence
    }

    /// One segment's contribution to one output track.
    struct Leg: Equatable {
        let source: LegSource
        /// Input-seek seconds of the kept window's start — `pts[in] − container
        /// start_time` (the ADR-0013/0015 trap), 0 when the in point is open.
        let seekBase: Double
        /// Where this leg starts on the assembled timeline, in output seconds.
        let outputStart: Double
        /// Leg length in output seconds: the segment's frames at the target rate.
        let duration: Double
    }

    /// Per-clip audio inputs, resolved by the caller (bookmarks → URLs, probes done):
    /// `sources[t]` feeds output track `t` exactly as the export's
    /// `ExportItem.audioSources` does — nil (and anything past the list's end) is
    /// silence.
    struct ClipAudio {
        let url: URL
        let containerStart: Double
        let sources: [ExportEngine.AudioSource?]
    }

    /// The output tracks the export would carry (`AudioSourceResolver.resolveOutputTracks`)
    /// — the picker's rows, and each leg's conform target.
    let tracks: [AudioCodecPolicy.OutputAudioTrack]
    /// `legs[track][segment]`, matching the timeline's segment order.
    let legs: [[Leg]]

    static func build(segments: [PreviewTimeline.Segment], targetFps: Double,
                      clips: [UUID: ClipAudio],
                      tracks: [AudioCodecPolicy.OutputAudioTrack]) -> PreviewAudioPlan {
        let fps = max(1.0, targetFps)
        let legs = tracks.indices.map { t in
            segments.map { segment -> Leg in
                let clip = clips[segment.clipID]
                let source: LegSource
                switch clip.flatMap({ t < $0.sources.count ? $0.sources[t] : nil }) {
                case .stream(let s):
                    source = .stream(clip!.url, streamIndex: s)
                case .external(let url, let s):
                    source = .stream(url, streamIndex: s)
                case nil:
                    source = .silence
                }
                return Leg(
                    source: source,
                    seekBase: max(0, segment.windowStart - (clip?.containerStart ?? 0)),
                    outputStart: Double(segment.outputStart) / fps,
                    duration: Double(segment.outputCount) / fps
                )
            }
        }
        return PreviewAudioPlan(tracks: tracks, legs: legs)
    }

    /// Joins leg (`track`, `segment`) at `outputTime` on the assembled timeline:
    /// the stream to spawn, where to seek it (`seekBase` plus the time already
    /// elapsed inside the leg), and how much of the leg remains — the spawn's
    /// duration cap, so a leg never plays past its clip's out point. nil for an
    /// out-of-range track or segment.
    func entry(track: Int, segment: Int, atOutputTime outputTime: Double)
        -> (source: LegSource, seekSeconds: Double, remaining: Double)? {
        guard track >= 0, track < legs.count,
              segment >= 0, segment < legs[track].count else { return nil }
        let leg = legs[track][segment]
        let offset = min(max(0, outputTime - leg.outputStart), leg.duration)
        return (leg.source, leg.seekBase + offset, leg.duration - offset)
    }

    /// The per-leg conform filter for `track` — the same rate/layout conform the
    /// export applies to every leg of that track's chain (ADR-0014), so the preview
    /// sounds like the export. nil for an out-of-range track.
    func conformFilter(track: Int) -> String? {
        guard track >= 0, track < tracks.count else { return nil }
        return ConformEngine.audioFilter(
            sampleRate: tracks[track].sampleRate, channels: tracks[track].channels)
    }

    /// The picker name for output track `t` (0-based), named like the cut-editor's
    /// dropdown: the track's container title when present, else "Track N", with the
    /// language tag appended (ADR-0014 naming).
    func trackName(_ t: Int) -> String {
        guard t >= 0, t < tracks.count else { return "Track \(t + 1)" }
        let track = tracks[t]
        let base = track.title?.isEmpty == false ? track.title! : "Track \(t + 1)"
        if let language = track.language, !language.isEmpty, language != "und" {
            return "\(base) (\(language))"
        }
        return base
    }
}
