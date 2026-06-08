import Foundation

/// A stream-copyable span of one clip, ready to drive the ffmpeg segment-muxer cut.
/// Milestone 2's boundary re-encode reuses it for the copy segment that sits between the
/// re-encoded head and tail (`BoundaryReencodeEngine.copySegmentPlan`): the span is
/// copied bit-exact while only the boundary GOPs are re-encoded (ADR-0009).
///
/// `inFrame`/`outFrame` describe the copied range; the segment times are what actually
/// drive ffmpeg. A `nil` segment time means that end is a clip boundary (the natural
/// file start/end), copied with no cut there.
struct SegmentPlan: Equatable {
    var inFrame: Int
    var outFrame: Int
    /// The ffmpeg `-segment_times` value that cuts exactly at the in/out frame (ADR-0008).
    /// `nil` at a clip boundary, where the natural file start/end is copied with no cut.
    var inSegmentTime: Double?
    var outSegmentTime: Double?
}
