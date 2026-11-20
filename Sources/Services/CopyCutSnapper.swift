import Foundation

enum CopyCutSnapper {
    static func snapInPoint(_ requested: Int, leadingCounts: [Int?]) -> Int? {
        nearest(to: requested,
                among: leadingCounts.indices.filter { leadingCounts[$0] == 0 },
                keepsRequestedFrameWhen: <)
    }

    static func snapOutPoint(_ requested: Int, leadingCounts: [Int?]) -> Int? {
        let candidates = leadingCounts.indices.compactMap { k -> Int? in
            guard let count = leadingCounts[k] else { return nil }
            let lastKept = k - count - 1
            return lastKept >= 0 ? lastKept : nil
        }
        return nearest(to: requested, among: candidates, keepsRequestedFrameWhen: >)
    }

    private static func nearest(
        to requested: Int, among candidates: [Int],
        keepsRequestedFrameWhen keeps: (Int, Int) -> Bool
    ) -> Int? {
        candidates.min { a, b in
            let (da, db) = (abs(a - requested), abs(b - requested))
            return da != db ? da < db : keeps(a, b)
        }
    }
}
