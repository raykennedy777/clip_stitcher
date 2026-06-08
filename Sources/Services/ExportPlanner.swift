import Foundation

/// A keyframe-aligned segment plan for one clip: the in/out frames snapped to clean
/// cut points (ADR-0008), ready to drive the ffmpeg segment-muxer cut.
struct SegmentPlan: Equatable {
    var inFrame: Int
    var outFrame: Int
    /// Whether the requested in/out frame was moved to reach a clean cut point —
    /// the UI surfaces this as a "cut snapped" warning.
    var inMoved: Bool
    var outMoved: Bool
    /// The ffmpeg `-segment_times` values that cut exactly at the snapped in/out
    /// frames (ADR-0008).
    var inSegmentTime: Double
    var outSegmentTime: Double
}

/// Turns a clip's chosen in/out frames into a Milestone 1 segment plan. Pure logic:
/// it only reads the frame index, so it is fully unit-testable without ffmpeg.
enum ExportPlanner {
    static func plan(index: FrameIndex, inFrame: Int, outFrame: Int) -> SegmentPlan {
        let snappedIn = index.nearestCleanCutPoint(to: inFrame)
        let snappedOut = index.nearestCleanCutPoint(to: outFrame)
        return SegmentPlan(
            inFrame: snappedIn,
            outFrame: snappedOut,
            inMoved: snappedIn != inFrame,
            outMoved: snappedOut != outFrame,
            inSegmentTime: index.segmentTime(forCutAt: snappedIn),
            outSegmentTime: index.segmentTime(forCutAt: snappedOut)
        )
    }
}
