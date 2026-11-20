import Foundation

enum SplitRanges {
    struct Range: Equatable {
        var inPoint: Int?
        var outPoint: Int?
    }

    static func isLive(_ frame: Int, inPoint: Int?, outPoint: Int?, lastFrame: Int) -> Bool {
        frame > (inPoint ?? 0) && frame <= (outPoint ?? lastFrame)
    }

    static func liveSplits(_ splits: Set<Int>, inPoint: Int?, outPoint: Int?, lastFrame: Int) -> [Int] {
        splits.filter { isLive($0, inPoint: inPoint, outPoint: outPoint, lastFrame: lastFrame) }.sorted()
    }

    static func ranges(splits: Set<Int>, inPoint: Int?, outPoint: Int?, lastFrame: Int) -> [Range] {
        let live = liveSplits(splits, inPoint: inPoint, outPoint: outPoint, lastFrame: lastFrame)
        var result: [Range] = []
        var start = inPoint
        for split in live {
            result.append(Range(inPoint: start, outPoint: split - 1))
            start = split
        }
        result.append(Range(inPoint: start, outPoint: outPoint))
        return result
    }
}
