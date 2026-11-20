import Foundation

struct PreviewTimeline {
    struct Segment {
        let clipID: UUID
        let outputStart: Int
        let outputCount: Int
        let keptStart: Int
        let keptEnd: Int
        let windowStart: Double
        let conformed: Bool
    }

    let segments: [Segment]
    let targetFps: Double

    var totalFrames: Int {
        segments.last.map { $0.outputStart + $0.outputCount } ?? 0
    }

    var joinFrames: [Int] {
        segments.dropFirst().map(\.outputStart)
    }

    struct ClipSpec {
        let clipID: UUID
        let pts: [Double]
        let inPoint: Int?
        let outPoint: Int?
        let duration: Double?
        let conformed: Bool
    }

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

    func locate(_ frame: Int) -> (segmentIndex: Int, local: Int)? {
        guard !segments.isEmpty else { return nil }
        let clamped = min(max(0, frame), totalFrames - 1)
        for (i, segment) in segments.enumerated()
        where clamped < segment.outputStart + segment.outputCount {
            return (i, clamped - segment.outputStart)
        }
        return (segments.count - 1, segments[segments.count - 1].outputCount - 1)
    }

    func sourceFrame(in segment: Segment, local local0: Int, pts: [Double]) -> Int {
        let local = min(max(0, local0), segment.outputCount - 1)
        guard segment.conformed else { return segment.keptStart + local }
        let time = segment.windowStart + Double(local) / targetFps
        return nearestFrame(to: time, in: pts, from: segment.keptStart, through: segment.keptEnd)
    }

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

    private func nearestFrame(to time: Double, in pts: [Double], from: Int, through: Int) -> Int {
        var lo = from, hi = through
        guard lo <= hi else { return from }
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        if lo > from, abs(pts[lo - 1] - time) <= abs(pts[lo] - time) { return lo - 1 }
        return lo
    }

    private static func frameRateValue(_ rate: String) -> Double? {
        let p = rate.split(separator: "/").compactMap { Double($0) }
        if p.count == 2 { return p[1] != 0 ? p[0] / p[1] : nil }
        if p.count == 1 { return p[0] > 0 ? p[0] : nil }
        return nil
    }
}
