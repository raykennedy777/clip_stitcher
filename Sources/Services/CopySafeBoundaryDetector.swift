import Foundation

enum CopySafeBoundaryDetector {
    static func copySafeFlags(keyframeFlags: [Bool], dts: [Double]) -> [Bool] {
        leadingPictureCounts(keyframeFlags: keyframeFlags, dts: dts).map { $0 == 0 }
    }

    static func leadingPictureCounts(keyframeFlags: [Bool], dts: [Double]) -> [Int?] {
        var prefixMaxDTS = dts
        for i in dts.indices.dropFirst() {
            prefixMaxDTS[i] = max(prefixMaxDTS[i - 1], dts[i])
        }
        var counts = Array<Int?>(repeating: nil, count: keyframeFlags.count)
        for i in keyframeFlags.indices where keyframeFlags[i] {
            var j = i - 1
            while j >= 0, dts[j] > dts[i] { j -= 1 }
            if j < 0 || prefixMaxDTS[j] < dts[i] { counts[i] = i - 1 - j }
        }
        return counts
    }
}
