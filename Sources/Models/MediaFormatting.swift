import Foundation

enum MediaFormatting {
    static func fps(_ raw: String) -> Double? {
        let parts = raw.split(separator: "/")
        guard parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 else {
            return nil
        }
        return num / den
    }

    static func frameRate(_ raw: String) -> String {
        guard let fps = fps(raw) else { return raw }
        return fps == fps.rounded() ? String(format: "%.0f", fps) : String(format: "%.3f", fps)
    }

    static func isProgressive(_ fieldOrder: String?) -> Bool {
        switch fieldOrder {
        case nil, "", "unknown", "progressive": return true
        default: return false
        }
    }

    static func scanType(_ fieldOrder: String?) -> String {
        isProgressive(fieldOrder) ? "Progressive" : "Interlaced (\(fieldOrder!))"
    }

    static func displayAspectRatio(width: Int, height: Int, sar: String?) -> String? {
        guard width > 0, height > 0 else { return nil }
        let (sn, sd) = sampleAspect(sar)
        let num = width * sn
        let den = height * sd
        let g = gcd(num, den)
        guard g > 0 else { return nil }
        return "\(num / g):\(den / g)"
    }

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

    static func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
