import Foundation

enum FieldCodingDetector {
    // ADR-0033
    static func isFieldCoded(packetPts: [Double], frameRates: [String?]) -> Bool {
        guard let display = frameRates.compactMap(fps).filter({ $0 > 0 }).min(),
              let interval = medianInterval(packetPts), interval > 0 else { return false }
        let packetsPerFrame = 1.0 / (interval * display)
        return abs(packetsPerFrame - 2.0) <= 0.3
    }

    static func medianInterval(_ pts: [Double]) -> Double? {
        guard pts.count >= 26 else { return nil }
        let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }
        return deltas.sorted()[deltas.count / 2]
    }

    private static func fps(_ rate: String?) -> Double? {
        let p = (rate ?? "").split(separator: "/").compactMap { Double($0) }
        guard p.count == 2, p[1] != 0 else { return nil }
        return p[0] / p[1]
    }
}
