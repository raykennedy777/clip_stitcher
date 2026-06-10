import Foundation

/// The assembled output timeline the preview scrubs (ADR-0012): every clip's selection
/// range becomes one run of **output frames at the target clip's frame rate** — the
/// frames the exported file will actually have. Pure math (no decoding) so the
/// output-frame ↔ source-frame mapping can be unit-tested.
///
/// A matching clip's frames pass through 1:1 (its fps equals the target's — fps is a
/// match dimension), so its output frames are just its kept source frames. A conformed
/// clip is re-timed: its output frame count is its kept *duration* at the target rate
/// (mirroring `ConformEngine.expectedFrameCount`), and each output frame maps to the
/// source frame nearest in time — the same drop/duplicate the conform's `fps` filter
/// performs, done by lookup instead of in the decode pipeline, which keeps the
/// decoder's frame-counting seek arithmetic intact (ADR-0012).
struct PreviewTimeline {
    struct Segment {
        let clipID: UUID
        /// First global output frame of this segment.
        let outputStart: Int
        let outputCount: Int
        /// The selection range, in source frame numbers (inclusive).
        let keptStart: Int
        let keptEnd: Int
        /// Presentation time of the kept window's start: `pts[inPoint]`, or 0 when the
        /// in point is the clip boundary — the same time window the export uses.
        let windowStart: Double
        let conformed: Bool
    }

    let segments: [Segment]
    let targetFps: Double

    /// Total output frames across all segments.
    var totalFrames: Int {
        segments.last.map { $0.outputStart + $0.outputCount } ?? 0
    }

    /// Global output frame of each join (where one clip ends and the next begins).
    var joinFrames: [Int] {
        segments.dropFirst().map(\.outputStart)
    }

    /// The inputs `build` needs per clip, in timeline order.
    struct ClipSpec {
        let clipID: UUID
        /// The clip's frame timestamps (`FrameIndex.pts`).
        let pts: [Double]
        /// Selection range in source frames; nil means the clip boundary.
        let inPoint: Int?
        let outPoint: Int?
        /// Probed file duration (seconds) — the conformed window's end when the out
        /// point is open, mirroring the export.
        let duration: Double?
        let conformed: Bool
    }

    /// Builds the timeline. `targetFrameRate` is the target clip's ffprobe rate
    /// ("25/1"); clips without frames are skipped.
    static func build(clips: [ClipSpec], targetFrameRate: String) -> PreviewTimeline {
        let fps = frameRateValue(targetFrameRate) ?? 25
        var segments: [Segment] = []
        var cursor = 0
        for clip in clips {
            guard !clip.pts.isEmpty else { continue }
            let last = clip.pts.count - 1
            let keptStart = min(max(0, clip.inPoint ?? 0), last)
            let keptEnd = min(max(keptStart, clip.outPoint ?? last), last)
            let windowStart = clip.inPoint == nil ? 0 : clip.pts[keptStart]

            let count: Int
            if clip.conformed {
                // The export's window: `pts[out]` (or the probed duration when the out
                // point is open) minus the window start, at the target rate.
                let windowEnd = clip.outPoint == nil
                    ? (clip.duration ?? clip.pts[last])
                    : clip.pts[keptEnd]
                count = ConformEngine.expectedFrameCount(
                    windowDuration: windowEnd - windowStart,
                    targetFrameRate: targetFrameRate
                ) ?? (keptEnd - keptStart + 1)
            } else {
                count = keptEnd - keptStart + 1
            }
            guard count > 0 else { continue }

            segments.append(Segment(
                clipID: clip.clipID,
                outputStart: cursor, outputCount: count,
                keptStart: keptStart, keptEnd: keptEnd,
                windowStart: windowStart, conformed: clip.conformed
            ))
            cursor += count
        }
        return PreviewTimeline(segments: segments, targetFps: fps)
    }

    /// The segment containing global output frame `frame`, and the frame's position
    /// within it. nil on an empty timeline; out-of-range frames clamp to the ends.
    func locate(_ frame: Int) -> (segmentIndex: Int, local: Int)? {
        guard !segments.isEmpty else { return nil }
        let clamped = min(max(0, frame), totalFrames - 1)
        for (i, segment) in segments.enumerated()
        where clamped < segment.outputStart + segment.outputCount {
            return (i, clamped - segment.outputStart)
        }
        return (segments.count - 1, segments[segments.count - 1].outputCount - 1)
    }

    /// The source frame to decode for `local` output frame of `segment`. Matching
    /// segments map 1:1 from the kept range. Conformed segments map through time:
    /// the output frame's timestamp (window start + local / target fps) to the
    /// nearest source frame, clamped to the kept range.
    func sourceFrame(in segment: Segment, local local0: Int, pts: [Double]) -> Int {
        let local = min(max(0, local0), segment.outputCount - 1)
        guard segment.conformed else { return segment.keptStart + local }
        let time = segment.windowStart + Double(local) / targetFps
        return nearestFrame(to: time, in: pts, from: segment.keptStart, through: segment.keptEnd)
    }

    /// The global output frame showing source frame `src` of `segment` — the
    /// inverse of `sourceFrame`. Matching segments map 1:1 from the kept range;
    /// conformed segments map through time (the source frame's timestamp at the
    /// target rate, rounded). Clamped into the segment either way.
    func outputFrame(forSource src: Int, in segment: Segment, pts: [Double]) -> Int {
        let local: Int
        if segment.conformed {
            guard !pts.isEmpty else { return segment.outputStart }
            let time = pts[min(max(0, src), pts.count - 1)]
            local = Int(((time - segment.windowStart) * targetFps).rounded())
        } else {
            local = src - segment.keptStart
        }
        return segment.outputStart + min(max(0, local), segment.outputCount - 1)
    }

    /// Output frames that act as keyframe anchors for ⇧←/⇧→ navigation (issue #8
    /// follow-up): every kept-range keyframe mapped to its output frame, plus each
    /// segment's first frame — a join is a clean seek anchor in the output (the
    /// export re-encodes from the in point), and it makes the keys walk across
    /// clips the way frame 0 anchors the cut-editor. Sorted ascending; `index`
    /// resolves a clip's frame index (a clip without one contributes only its
    /// segment start).
    func keyframeAnchorFrames(index: (UUID) -> FrameIndex?) -> [Int] {
        var anchors: Set<Int> = []
        for segment in segments {
            anchors.insert(segment.outputStart)
            guard let idx = index(segment.clipID) else { continue }
            var keyframe = idx.keyframeIndex(after: segment.keptStart - 1)
            while let src = keyframe, src <= segment.keptEnd {
                anchors.insert(outputFrame(forSource: src, in: segment, pts: idx.pts))
                keyframe = idx.keyframeIndex(after: src)
            }
        }
        return anchors.sorted()
    }

    /// Binary search for the frame whose timestamp is nearest `time` within
    /// `[from, through]` (inclusive).
    private func nearestFrame(to time: Double, in pts: [Double], from: Int, through: Int) -> Int {
        var lo = from, hi = through
        guard lo <= hi else { return from }
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        // `lo` is the first frame at/after `time`; its predecessor may be nearer.
        if lo > from, abs(pts[lo - 1] - time) <= abs(pts[lo] - time) { return lo - 1 }
        return lo
    }

    /// Frames-per-second from an ffprobe "num/den" rate; nil when unparseable.
    private static func frameRateValue(_ rate: String) -> Double? {
        let p = rate.split(separator: "/").compactMap { Double($0) }
        if p.count == 2 { return p[1] != 0 ? p[0] / p[1] : nil }
        if p.count == 1 { return p[0] > 0 ? p[0] : nil }
        return nil
    }
}
