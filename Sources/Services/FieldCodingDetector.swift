import Foundation

/// Detects field-coded (PAFF) sources at import (issue #46): interlaced broadcast
/// captures that store each *field* as its own packet — two packets per displayed
/// frame. The frame index counts packets as frames (ADR-0006), so on such a source
/// every frame number, scrubber position, cut point, and frame-count verification is
/// off by a factor of two. This slice detects and warns; it does not add PAFF support.
///
/// Detection compares the **measured packet cadence** (median packet interval from the
/// index's timestamps — never header metadata, which is exactly what lies on these
/// files) against the probed display rate. The real capture probes avg_frame_rate
/// 50/1 (ffprobe derives it from packet count, so it is the *field* rate) and
/// r_frame_rate 25/1 (the codec's true display rate) — the display rate is the
/// **lower** of the two. Taking the minimum also keeps the inverse quirk safe: an
/// MBAFF-style file reporting r_frame_rate at the field rate over a true one-packet-
/// per-frame stream measures cadence ≈ 1× the lower rate and stays unflagged.
enum FieldCodingDetector {
    /// Whether the video stream is field-coded: the measured packet cadence is ~2×
    /// the probed display rate. `packetPts` is the frame index's presentation
    /// timestamps (sorted); `frameRates` are the probed candidates (avg_frame_rate,
    /// r_frame_rate) — unparseable or missing entries are ignored. Conservative on
    /// thin evidence: too few packets (< 25 intervals) or no parseable rate is `false`.
    static func isFieldCoded(packetPts: [Double], frameRates: [String?]) -> Bool {
        guard let display = frameRates.compactMap(fps).filter({ $0 > 0 }).min(),
              let interval = medianInterval(packetPts), interval > 0 else { return false }
        let packetsPerFrame = 1.0 / (interval * display)
        return abs(packetsPerFrame - 2.0) <= 0.3
    }

    /// The median interval between consecutive timestamps — robust against the stray
    /// duplicate/gap anomalies real broadcast captures carry (ADR-0008's ~714 on the
    /// BBC fixture). `nil` below 25 intervals: too thin to call a cadence.
    static func medianInterval(_ pts: [Double]) -> Double? {
        guard pts.count >= 26 else { return nil }
        let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }
        return deltas.sorted()[deltas.count / 2]
    }

    /// Frames-per-second from an ffprobe "num/den" rate; nil when unparseable/degenerate.
    private static func fps(_ rate: String?) -> Double? {
        let p = (rate ?? "").split(separator: "/").compactMap { Double($0) }
        guard p.count == 2, p[1] != 0 else { return nil }
        return p[0] / p[1]
    }
}
