import Foundation

/// Decides which keyframes are *copy-safe boundaries* for Milestone 2's boundary
/// re-encode (ADR-0009): the keyframes a stream-copied middle may start and end on
/// without dragging in **orphaned leading pictures** at the re-encode→copy seam.
///
/// This is the *general* leading-picture-free test, applied uniformly to **every**
/// codec — including MPEG-2, whose open-GOP I-frames are *not* automatically copy-safe
/// here: M2 *re-encodes* the prior GOP, so any leading pictures that reference across the
/// boundary would be orphaned at the re-encode→copy seam. A keyframe qualifies only when
/// nothing presented before it decodes later than it does.
///
/// The test reads only the per-frame DTS the frame index already carries (ADR-0006), so
/// it needs no extra ffmpeg pass and the index need not be rebuilt — which also keeps the
/// future libav minimal-recode path (Milestone 2b) open, since the per-frame
/// leading-picture structure is recoverable from the same DTS.
enum CopySafeBoundaryDetector {
    /// A presentation-order flag (parallel to `FrameIndex`) marking the keyframes a
    /// stream copy may start/end on. A keyframe is copy-safe when nothing presented
    /// before it decodes later than it does — i.e. it has no leading pictures.
    static func copySafeFlags(keyframeFlags: [Bool], dts: [Double]) -> [Bool] {
        var flags = Array(repeating: false, count: keyframeFlags.count)
        // Running max of every earlier-presented frame's DTS. A keyframe is copy-safe
        // when nothing presented before it decodes later than it does.
        var maxEarlierDTS = -Double.greatestFiniteMagnitude
        for i in keyframeFlags.indices {
            if keyframeFlags[i] && maxEarlierDTS < dts[i] {
                flags[i] = true
            }
            if dts[i] > maxEarlierDTS { maxEarlierDTS = dts[i] }
        }
        return flags
    }
}
