import Foundation

struct PreviewAudioPlan {
    enum LegSource: Equatable {
        case stream(URL, streamIndex: Int)
        case silence
    }

    struct Leg: Equatable {
        let source: LegSource
        let seekBase: Double
        let outputStart: Double
        let duration: Double
        let mixFilter: String?
    }

    struct ClipAudio {
        let url: URL
        let containerStart: Double
        let sources: [ExportEngine.AudioSource?]
        var mixFilters: [String?] = []
    }

    let tracks: [AudioCodecPolicy.OutputAudioTrack]
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
                    duration: Double(segment.outputCount) / fps,
                    mixFilter: clip.flatMap { t < $0.mixFilters.count ? $0.mixFilters[t] : nil }
                )
            }
        }
        return PreviewAudioPlan(tracks: tracks, legs: legs)
    }

    func entry(track: Int, segment: Int, atOutputTime outputTime: Double)
        -> (source: LegSource, seekSeconds: Double, remaining: Double)? {
        guard track >= 0, track < legs.count,
              segment >= 0, segment < legs[track].count else { return nil }
        let leg = legs[track][segment]
        let offset = min(max(0, outputTime - leg.outputStart), leg.duration)
        return (leg.source, leg.seekBase + offset, leg.duration - offset)
    }

    func conformFilter(track: Int) -> String? {
        guard track >= 0, track < tracks.count else { return nil }
        return ConformEngine.audioFilter(
            sampleRate: tracks[track].sampleRate, channels: tracks[track].channels)
    }

    func legFilter(track: Int, segment: Int) -> String? {
        let conform = conformFilter(track: track)
        guard track >= 0, track < legs.count,
              segment >= 0, segment < legs[track].count,
              let mix = legs[track][segment].mixFilter else { return conform }
        return conform.map { mix + "," + $0 } ?? mix
    }

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
