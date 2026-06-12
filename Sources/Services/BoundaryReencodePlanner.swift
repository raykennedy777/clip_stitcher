import Foundation

/// One logical piece of a Milestone 2 export: a contiguous presentation-frame range
/// produced either by a stream **copy** (a keyframe-bounded span, frame-exact and cheap)
/// or by a **re-encode** (the partial GOPs at the head/tail of the kept range).
///
/// The plan is a list of these in output order, kept deliberately separate from how they
/// are executed: the CLI backend maps a copy to a segment-muxer cut and a re-encode to a
/// frame-selected libx26x/mpeg2 pass, while a future libav backend (Milestone 2b) can
/// consume the same plan and add a third *re-encode-leading-pictures-only* kind without
/// reshaping it (ADR-0009).
struct PlannedSegment: Equatable {
    enum Kind { case copy, reEncode }
    var kind: Kind
    /// Presentation frames covered, half-open `[lowerBound, upperBound)`.
    var range: Range<Int>
    /// For a copy segment trimmed at its tail: the keyframe anchoring the segment-muxer
    /// out-cut. The cut lands just before this keyframe's DTS, which keeps exactly
    /// `range` — the keyframe's leading pictures (presented before it, decoded after it)
    /// fall into the *discarded* segment, so `range.upperBound` is the keyframe's index
    /// minus its leading-picture count (#16). On clean boundaries the two coincide.
    /// `nil` on a copy that runs to the clip end, and on re-encodes.
    var outCutKeyframe: Int? = nil
    /// The damage zones this segment repairs (issue #47) — non-empty only on a
    /// re-encode forced by damage. The executor then uses the time-window select
    /// recipe (drop each zone's span, fps-fill with the held frame) instead of the
    /// frame-number select: at every truncated no-timestamp packet the index and the
    /// decoder's emitted-frame numbering drift apart by one, so `between(n,…)`
    /// desyncs precisely where it matters. Zone times are container-start-relative,
    /// as recorded (`DamageZone`).
    var damage: [DamageZone] = []
}

/// Turns a clip's kept range into a Milestone 2 segment plan (ADR-0009). Pure logic over
/// the per-keyframe leading-picture counts (`CopySafeBoundaryDetector`), so it is fully
/// unit-testable without ffmpeg.
///
/// `inFrame`/`outFrame` are exact presentation frames the user chose — M2 does **not**
/// snap them to clean points (that is the whole advantage over M1); it only re-encodes
/// the partial GOPs needed to reach the nearest legal copy boundaries. A `nil` in/out is
/// the clip boundary (file start / end): that end is copied with no cut and no re-encode,
/// so a whole-clip keep is a pure copy, never worse than M1.
///
/// The boundary rules are asymmetric (#16): a copy may START only at a
/// leading-picture-free keyframe (count 0 — anything looser would orphan the leading
/// pictures at the re-encode→copy seam), but may END at *any* counted keyframe `K`, at
/// presentation index `K − n_leading`: the segment-muxer cut just before `K` sends its
/// leading pictures into the discarded segment, no bitstream surgery needed. On
/// closed-GOP footage every count is 0 and both rules collapse to the pre-#16 behavior.
enum BoundaryReencodePlanner {
    /// One damage zone mapped onto the frame index: the index frames its time range
    /// brackets, plus the zone itself for the repaired segment to carry. The range is
    /// legitimately **empty** when the zone's packets are missing entirely (a pure
    /// hole) — the bracketing boundaries still force a repair around it.
    struct DamageSpan: Equatable {
        var range: Range<Int>
        var zone: DamageZone
    }

    /// Maps a clip's recorded zones (issue #45) onto index frames by absolute time —
    /// zone times are container-start-relative (`DamageZone`), the index pts absolute.
    /// Frame planning comes from the zone *times*, never from index gaps: several real
    /// zones are decoder-level holes whose packets are all present (the index shows no
    /// gap there). Audio-only zones drop out — the defensive audio legs (issue #44)
    /// already repair those with silence.
    ///
    /// The upper bound widens past the zone until the next frame's **dts** clears
    /// every timestamp inside it (max dts and max pts): the copy cut resuming after
    /// the repair is placed on its boundary keyframe's dts, and an in-zone packet
    /// whose garbled timestamps reach past that cut would be swept into the kept
    /// copy — the h264 fixture's mis-framed garbage packets put 3 in-zone packets
    /// into a kept piece and a timestamp-less choke into the concat (#47 validation).
    /// On a clean B-frame cadence the widening is just the reorder depth; with
    /// dts == pts (or a pure hole) it is zero.
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

    /// The first index whose pts is at/after `t` (`pts.count` when none is).
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
        damage: [DamageSpan] = []
    ) -> [PlannedSegment] {
        let inStart = inFrame ?? 0
        let outEx = outFrame.map { $0 + 1 } ?? frameCount
        guard outEx > inStart else { return [] }

        let relevant = damage
            .filter { $0.range.upperBound > inStart && $0.range.lowerBound < outEx }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard !relevant.isEmpty else {
            // The undamaged path, unchanged — a clip with no zones in range plans
            // exactly as before damage repair existed (issue #47 acceptance).
            return planUndamaged(leadingCounts: leadingCounts, frameCount: frameCount,
                                 inFrame: inFrame, outFrame: outFrame)
        }

        // Each zone forces a repair re-encode extending to the surrounding copy-safe
        // boundaries: left to the deepest legal copy END (`K − n_leading`, #16) at
        // least one frame before the first damaged frame — the repair must keep a good
        // frame to hold across the zone (the fps fill repeats the last frame *within*
        // the re-encoded piece; the preceding copy can't lend one) — and right to the
        // first copy-safe START at/after the damage. No boundary means the repair runs
        // to the kept range's edge, swallowing the head/tail re-encode.
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

        // Tile the kept range: copy the clean gaps between repairs. A gap's right edge
        // is its repair's left boundary (a legal copy end, cut at `loCut`); an interior
        // gap starts at the previous repair's right boundary (a copy-safe start by
        // construction). Only the head gap from a cut in-point must still find its own
        // copy-safe start; a gap with none re-encodes whole and merges into its repair.
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
            // The tail gap reuses the undamaged path's copy-end rule with the repair's
            // right boundary as its (already copy-safe) start.
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

        // A gap that couldn't copy is a bare re-encode beside a repair — one ffmpeg
        // run, not two, and no seam inside damaged territory.
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

    /// A clean gap `[from, to)` ending at a repair's left boundary: an optional head
    /// re-encode up to the first copy-safe start, then the copy cut at `outCut`.
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
        leadingCounts: [Int?], frameCount: Int, inFrame: Int?, outFrame: Int?
    ) -> [PlannedSegment] {
        let inStart = inFrame ?? 0
        let outEx = outFrame.map { $0 + 1 } ?? frameCount

        // Where a frame-exact stream copy can begin: the file start needs no in-cut;
        // otherwise the first leading-picture-free keyframe at/after the in-point.
        let copyStart: Int? = inFrame == nil
            ? inStart
            : leadingCounts.indices.first {
                leadingCounts[$0] == 0 && $0 >= inStart && $0 < outEx
            }

        // Where it can end: the file end needs no out-cut. Otherwise the keyframe whose
        // cut-before-it end (`K − n_leading`) reaches deepest into the kept range — the
        // keyframe itself may sit beyond the out-point when only its leading-picture
        // slots are trimmed off.
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
            // No copy span fits — re-encode the whole kept range (sparse clean points).
            return [PlannedSegment(kind: .reEncode, range: inStart..<outEx)]
        }

        var segments: [PlannedSegment] = []
        if start > inStart { segments.append(PlannedSegment(kind: .reEncode, range: inStart..<start)) }
        segments.append(PlannedSegment(kind: .copy, range: start..<end, outCutKeyframe: cutKeyframe))
        if end < outEx { segments.append(PlannedSegment(kind: .reEncode, range: end..<outEx)) }
        return segments
    }
}
