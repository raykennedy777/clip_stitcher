import Foundation

/// One damaged region of a clip's source, recorded at import (issue #45). Detection
/// only — a clip with zero zones behaves exactly as before; the repair slices (#47,
/// #48) consume these to plan re-encodes and reports.
///
/// Times are source seconds measured **from the container's start_time** — the same
/// base as input-seek seconds (`ExportEngine.KeptWindow`), so the export paths can
/// seek/select with them directly and the UI can show them as clip time. Absolute
/// presentation time = value + the container start.
struct DamageZone: Codable, Equatable {
    /// Where the damage begins: just past the last good content before it.
    var start: Double
    /// Where good content resumes.
    var end: Double
    /// Whether confirmed video damage (corrupt or missing frames) lies inside.
    /// `false` is an audio-only gap — the defensive audio legs (issue #44) already
    /// fill it with silence; no video repair is needed there.
    var affectsVideo: Bool
}
