import Foundation

struct PlannedSegment: Equatable {
    enum Kind { case copy, reEncode }
    var kind: Kind
    var range: Range<Int>
    var outCutKeyframe: Int? = nil
    var damage: [DamageZone] = []
    var droppedLeadingPictures: Int = 0
}

enum BoundaryReencodePlanner {
    struct DamageSpan: Equatable {
        var range: Range<Int>
        var zone: DamageZone
    }

    static func damageSpans(zones: [DamageZone], pts: [Double], dts: [Double]? = nil,
                            containerStart: Double) -> [DamageSpan] {
        let dts = dts ?? pts
        return zones.filter(\.affectsVideo).map { zone in
            let lo = insertionIndex(pts, zone.start + containerStart)
            var hi = max(lo, insertionIndex(pts, zone.end + containerStart))
            if hi > lo, dts.count == pts.count {
                let zoneMax = max(dts[lo..<hi].max() ?? -.infinity, pts[hi - 1])
                while hi < pts.count, dts[hi] <= zoneMax + 1e-9 { hi += 1 }
            }
            return DamageSpan(range: lo..<hi, zone: zone)
        }
    }

    private static func insertionIndex(_ pts: [Double], _ t: Double) -> Int {
        var low = 0, high = pts.count
        while low < high {
            let mid = (low + high) / 2
            if pts[mid] < t { low = mid + 1 } else { high = mid }
        }
        return low
    }

    static func plan(
        leadingCounts: [Int?], frameCount: Int, inFrame: Int?, outFrame: Int?,
        damage: [DamageSpan] = [], openInPoint: Bool = false
    ) -> [PlannedSegment] {
        let inStart = inFrame ?? 0
        let outEx = outFrame.map { $0 + 1 } ?? frameCount
        guard outEx > inStart else { return [] }

        let relevant = damage
            .filter { $0.range.upperBound > inStart && $0.range.lowerBound < outEx }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard !relevant.isEmpty else {
            return planUndamaged(leadingCounts: leadingCounts, frameCount: frameCount,
                                 inFrame: inFrame, outFrame: outFrame, openInPoint: openInPoint)
        }

        struct Repair { var lo: Int; var hi: Int; var loCut: Int?; var zones: [DamageZone] }
        var repairs: [Repair] = []
        for span in relevant {
            var left = (end: inStart, cut: Int?.none)
            for k in leadingCounts.indices {
                guard let n = leadingCounts[k] else { continue }
                let end = k - n
                if end > left.end, end <= span.range.lowerBound - 1 { left = (end, k) }
            }
            let right = leadingCounts.indices.first {
                leadingCounts[$0] == 0 && $0 >= span.range.upperBound && $0 < outEx
            } ?? outEx
            if var last = repairs.last, left.end <= last.hi {
                last.hi = max(last.hi, right)
                last.zones.append(span.zone)
                repairs[repairs.count - 1] = last
            } else {
                repairs.append(Repair(lo: left.end, hi: right, loCut: left.cut, zones: [span.zone]))
            }
        }

        var segments: [PlannedSegment] = []
        var cursor = inStart
        for repair in repairs {
            if cursor < repair.lo {
                segments += gapSegments(from: cursor, to: repair.lo, outCut: repair.loCut,
                                        needsSafeStart: cursor == inStart && inFrame != nil,
                                        leadingCounts: leadingCounts)
            }
            segments.append(PlannedSegment(kind: .reEncode, range: repair.lo..<repair.hi,
                                           damage: repair.zones))
            cursor = repair.hi
        }
        if cursor < outEx {
            if outFrame == nil {
                segments.append(PlannedSegment(kind: .copy, range: cursor..<frameCount))
            } else {
                var best: (end: Int, cutKeyframe: Int)?
                for k in leadingCounts.indices {
                    guard let n = leadingCounts[k] else { continue }
                    let end = k - n
                    if end > (best?.end ?? cursor), end <= outEx { best = (end, k) }
                }
                if let (end, cut) = best {
                    segments.append(PlannedSegment(kind: .copy, range: cursor..<end, outCutKeyframe: cut))
                    if end < outEx { segments.append(PlannedSegment(kind: .reEncode, range: end..<outEx)) }
                } else {
                    segments.append(PlannedSegment(kind: .reEncode, range: cursor..<outEx))
                }
            }
        }

        var merged: [PlannedSegment] = []
        for segment in segments {
            if let last = merged.last, last.kind == .reEncode, segment.kind == .reEncode {
                merged[merged.count - 1] = PlannedSegment(
                    kind: .reEncode, range: last.range.lowerBound..<segment.range.upperBound,
                    damage: last.damage + segment.damage)
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private static func gapSegments(
        from: Int, to: Int, outCut: Int?, needsSafeStart: Bool, leadingCounts: [Int?]
    ) -> [PlannedSegment] {
        var start = from
        if needsSafeStart {
            guard let safe = leadingCounts.indices.first(where: {
                leadingCounts[$0] == 0 && $0 >= from && $0 < to
            }) else {
                return [PlannedSegment(kind: .reEncode, range: from..<to)]
            }
            start = safe
        }
        var segments: [PlannedSegment] = []
        if start > from { segments.append(PlannedSegment(kind: .reEncode, range: from..<start)) }
        if start < to { segments.append(PlannedSegment(kind: .copy, range: start..<to, outCutKeyframe: outCut)) }
        return segments
    }

    private static func planUndamaged(
        leadingCounts: [Int?], frameCount: Int, inFrame: Int?, outFrame: Int?,
        openInPoint: Bool
    ) -> [PlannedSegment] {
        let inStart = inFrame ?? 0
        let outEx = outFrame.map { $0 + 1 } ?? frameCount

        // ADR-0038
        let copyStart: Int? = inFrame == nil
            ? inStart
            : leadingCounts.indices.first {
                guard $0 >= inStart, $0 < outEx, let n = leadingCounts[$0] else { return false }
                return n == 0 || openInPoint
            }
        let dropped = inFrame == nil ? 0 : copyStart.flatMap { leadingCounts[$0] } ?? 0

        let copyEnd: (end: Int, cutKeyframe: Int?)? = {
            guard let start = copyStart else { return nil }
            if outFrame == nil { return (frameCount, nil) }
            var best: (end: Int, cutKeyframe: Int?)?
            for k in leadingCounts.indices {
                guard let n = leadingCounts[k] else { continue }
                let end = k - n
                if end > (best?.end ?? start), end <= outEx { best = (end, k) }
            }
            return best
        }()

        guard let start = copyStart, let (end, cutKeyframe) = copyEnd, end > start else {
            return [PlannedSegment(kind: .reEncode, range: inStart..<outEx)]
        }

        var segments: [PlannedSegment] = []
        if start > inStart { segments.append(PlannedSegment(kind: .reEncode, range: inStart..<start)) }
        segments.append(PlannedSegment(kind: .copy, range: start..<end, outCutKeyframe: cutKeyframe,
                                       droppedLeadingPictures: dropped))
        if end < outEx { segments.append(PlannedSegment(kind: .reEncode, range: end..<outEx)) }
        return segments
    }
}
