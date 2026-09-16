import Foundation

/// Video stream properties relevant to target-clip matching (see ADR-0005).
struct VideoProperties: Codable, Equatable, Sendable {
    var codec: String
    var profile: String?
    var level: String?
    var width: Int
    var height: Int
    /// Average frame rate as reported by ffprobe, e.g. "25/1".
    var frameRate: String
    var pixelFormat: String
    /// progressive, tt (top-first), bb (bottom-first), etc.
    var fieldOrder: String?
    /// Sample (pixel) aspect ratio, e.g. "1:1".
    var sampleAspectRatio: String?
    var colorPrimaries: String?
    var colorTransfer: String?
    /// The YUV↔RGB matrix coefficients (ffprobe `color_space`, e.g. "bt470bg") — the third
    /// leg of the color triple alongside primaries and transfer (issue #35). Defaulted so
    /// saves made before the field decode as nil (untagged), which is also what an untagged
    /// stream probes as.
    var colorSpace: String? = nil
    var colorRange: String?
    /// The stream's **reorder depth** (ffprobe `has_b_frames`): how many frames a decoder
    /// must hold back to emit them in presentation order. 0/1 for simple B-frame cadences,
    /// 2 once B-frames reference other B-frames (a B-pyramid — both x264's and x265's
    /// default). Not a match dimension: it says nothing about how a clip *looks*, only how
    /// deeply its decode order is shuffled — which is what a Matroska join has to agree on
    /// (`ExportEngine.joinReorderDepth`, ADR-0026). Defaulted so older saves decode as nil,
    /// which the join treats as the shallow 1.
    var reorderDepth: Int? = nil
    /// The **video stream's** average bit rate in bits/sec — the rate a re-encoded piece
    /// aims at when its encoder has no CRF mode (issue #110, MPEG-2). Never the format-level
    /// bit rate, which includes the audio tracks' share. Measured, not guessed: the
    /// container's reported `bit_rate` when it carries one, else — for MPEG-2, the only
    /// family that needs the number — a bounded packet sample (`MediaProbe`). nil when
    /// neither is available (and on every CRF-capable source, which doesn't need it), so
    /// older saves decode too.
    var bitrate: Int? = nil
}

/// One probed audio stream of a source file (ADR-0014). `language`/`title` come from
/// container tags — full names generally only exist on MKV sources; TS and MP4 carry
/// language at best. Both decode as nil from saves made before multi-track audio.
struct AudioProperties: Codable, Equatable, Sendable {
    var codec: String
    var sampleRate: Int
    var channels: Int
    var channelLayout: String?
    /// ISO language tag from the container (e.g. "eng"), if any.
    var language: String? = nil
    /// Human-readable track title from the container (e.g. "World Feed"), if any.
    var title: String? = nil
    /// The stream's average bit rate in bits/sec, as the container reports it — nil when
    /// it reports none (MKV and MP4 often omit it; TS broadcast captures carry it). Not a
    /// match dimension and never an export input: the rebuilt audio encodes at
    /// `ExportEngine.audioBitrate` whatever the source rate was (ADR-0010). It exists so a
    /// plan query can print source rate beside output rate (issue #115) and make a drop
    /// like 384k → 192k visible before the render, not after. Defaulted so older saves
    /// decode.
    var bitrate: Int? = nil

    /// The name shown for this track (ADR-0014): the container title when present,
    /// else "Track N"; the language tag is always appended when present.
    /// e.g. "World Feed (eng)", "Natural Sounds", "Track 2 (spa)", "Track 3".
    func displayName(trackNumber: Int) -> String {
        let base = title?.isEmpty == false ? title! : "Track \(trackNumber)"
        if let language, !language.isEmpty, language != "und" {
            return "\(base) (\(language))"
        }
        return base
    }
}
