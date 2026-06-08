import Foundation

/// Decides which keyframes are *copy-safe boundaries* for Milestone 2's boundary
/// re-encode (ADR-0009): the keyframes a stream-copied middle may start and end on
/// without dragging in **orphaned leading pictures** at the re-encode→copy seam.
///
/// This is the *general* leading-picture-free test, applied uniformly to **every**
/// codec. It differs deliberately from M1's `CleanCutDetector`, which may treat all
/// MPEG-2 I-frames as clean: M1's copy→copy concat keeps the prior segment whose frames
/// the leading B's reference, but M2 *re-encodes* the prior GOP, orphaning those leading
/// pictures — so the MPEG-2 shortcut is unsafe here. The two notions are kept distinct
/// so M1 does not regress.
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
