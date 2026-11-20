import Foundation

struct FrameIndex {
    let pts: [Double]
    let dts: [Double]
    let keyframeFlags: [Bool]

    init(pts: [Double], dts: [Double]? = nil, keyframeFlags: [Bool]) {
        self.pts = pts
        self.dts = dts ?? pts
        self.keyframeFlags = keyframeFlags
    }

    var count: Int { pts.count }

    var durationSpan: Double {
        guard let first = pts.first, let last = pts.last, last > first else { return 0 }
        return last - first
    }

    // ADR-0006
    func keyframeIndex(atOrBefore n: Int) -> Int? {
        var i = min(n, keyframeFlags.count - 1)
        while i >= 0 {
            if keyframeFlags[i] { return i }
            i -= 1
        }
        return nil
    }

    func keyframeIndex(after n: Int) -> Int? {
        let start = max(0, n + 1)
        guard start < keyframeFlags.count else { return nil }
        for i in start..<keyframeFlags.count where keyframeFlags[i] {
            return i
        }
        return nil
    }

    func frameIndex(atOrBeforeTime t: Double) -> Int {
        guard let first = pts.first, t >= first else { return 0 }
        var low = 0
        var high = pts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if pts[mid] <= t { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // ADR-0008
    func segmentTime(forCutAt n: Int) -> Double {
        let startOffset = pts.first ?? 0
        let cut = dts[n]
        var predecessor: Double? = nil
        var earlierKeyframePts: Double? = nil
        for i in dts.indices where dts[i] < cut {
            if predecessor == nil || dts[i] > predecessor! { predecessor = dts[i] }
            if i < keyframeFlags.count, keyframeFlags[i],
               earlierKeyframePts == nil || pts[i] > earlierKeyframePts! {
                earlierKeyframePts = pts[i]
            }
        }
        guard let prev = predecessor else { return cut / 2 - startOffset }
        var time = (prev + cut) / 2
        if let k = earlierKeyframePts, k >= time, k < pts[n] {
            time = (k + pts[n]) / 2
        }
        return time - startOffset
    }
}
