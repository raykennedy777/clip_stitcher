import Foundation

/// A keyframe-aligned segment plan for one clip: the in/out frames snapped to clean
/// cut points (ADR-0008), ready to drive the ffmpeg segment-muxer cut.
struct SegmentPlan: Equatable {
    var inFrame: Int
    var outFrame: Int
    /// Whether the requested in/out frame was moved to reach a clean cut point —
    /// the UI surfaces this as a "cut snapped" warning. A clip boundary is never
    /// "moved".
    var inMoved: Bool
    var outMoved: Bool
    /// The ffmpeg `-segment_times` value that cuts exactly at the snapped in/out
    /// frame (ADR-0008). `nil` at a clip boundary, where the natural file start/end
    /// is copied with no cut.
    var inSegmentTime: Double?
    var outSegmentTime: Double?

    /// Whether the plan describes a non-empty range. Snapping can collapse a
    /// selection (an in-point snapping forward past, or onto, the out-point), which
    /// has nothing to export — the UI refuses such a plan.
    var isValid: Bool { outFrame > inFrame }
}

/// Turns a clip's chosen in/out frames into a Milestone 1 segment plan. Pure logic:
/// it only reads the frame index, so it is fully unit-testable without ffmpeg.
///
/// A `nil` in/out frame means the clip boundary (start / end). Boundaries are copied
/// as-is — never snapped to a clean cut point (that would truncate the clip) and with
/// no cut at that end.
enum ExportPlanner {
    static func plan(index: FrameIndex, inFrame: Int?, outFrame: Int?) -> SegmentPlan {
        let snappedIn = inFrame.map { index.nearestCleanCutPoint(to: $0) }
        let snappedOut = outFrame.map { index.nearestCleanCutPoint(to: $0) }
        return SegmentPlan(
            inFrame: snappedIn ?? 0,
            outFrame: snappedOut ?? index.count - 1,
            inMoved: snappedIn != nil && snappedIn != inFrame,
            outMoved: snappedOut != nil && snappedOut != outFrame,
            inSegmentTime: snappedIn.map { index.segmentTime(forCutAt: $0) },
            outSegmentTime: snappedOut.map { index.segmentTime(forCutAt: $0) }
        )
    }
}
