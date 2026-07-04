import Foundation

/// Shared, pure formatting for media properties displayed across the UI — the Source
/// row's detail line and the clip inspector (issue #88). Centralised so the two can't
/// drift on how a frame rate, aspect ratio, size, or duration reads.
enum MediaFormatting {
    /// Frames-per-second from an ffprobe "num/den" rate ("25/1" → 25.0,
    /// "30000/1001" → 29.97); nil for a missing or degenerate value.
    static func fps(_ raw: String) -> Double? {
        let parts = raw.split(separator: "/")
        guard parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 else {
            return nil
        }
        return num / den
    }

    /// A frame rate as a compact display string: whole rates drop their decimals
    /// ("25/1" → "25"), fractional rates keep three ("30000/1001" → "29.970").
    static func frameRate(_ raw: String) -> String {
        guard let fps = fps(raw) else { return raw }
        return fps == fps.rounded() ? String(format: "%.0f", fps) : String(format: "%.3f", fps)
    }

    /// Whether an ffprobe `field_order` denotes a progressive scan: a missing, empty,
    /// "unknown", or "progressive" value. The single predicate the Source row's detail line
    /// and the inspector's scan-type both classify through, so they can't disagree on an
    /// ambiguous "unknown" (which reads as progressive, matching `MatchEvaluator`'s
    /// normalization — a clean progressive stream often reports no field order at all).
    static func isProgressive(_ fieldOrder: String?) -> Bool {
        switch fieldOrder {
        case nil, "", "unknown", "progressive": return true
        default: return false
        }
    }

    /// The scan-type gloss for a field order, plain-language per CONTEXT.md: a progressive
    /// order (see `isProgressive`) reads "Progressive"; an interlaced order (`tt`/`bb`/`tb`/`bt`)
    /// is named "Interlaced (tt)".
    static func scanType(_ fieldOrder: String?) -> String {
        isProgressive(fieldOrder) ? "Progressive" : "Interlaced (\(fieldOrder!))"
    }

    /// The display aspect ratio as a reduced "W:H" string, folding the sample (pixel)
    /// aspect into the stored dimensions: 720×576 @ 16:15 → "4:3", 1920×1080 @ 1:1 →
    /// "16:9". nil for degenerate dimensions.
    static func displayAspectRatio(width: Int, height: Int, sar: String?) -> String? {
        guard width > 0, height > 0 else { return nil }
        let (sn, sd) = sampleAspect(sar)
        // DAR in integer terms: (w·sarNum) : (h·sarDen), then reduced by the gcd.
        let num = width * sn
        let den = height * sd
        let g = gcd(num, den)
        guard g > 0 else { return nil }
        return "\(num / g):\(den / g)"
    }

    /// An ffprobe SAR ("64:45", "1:1") as an integer pair; missing/degenerate → (1, 1).
    private static func sampleAspect(_ sar: String?) -> (Int, Int) {
        let p = (sar ?? "1:1").split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { return (1, 1) }
        return (p[0], p[1])
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// A byte count as a human file size, matching Finder's decimal units.
    static func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// A duration in seconds as h:mm:ss (or m:ss under an hour), rounded to the second.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
