import Foundation

/// Decides which keyframes are *clean cut points* — the only places Milestone 1 will
/// cut, because a pure stream-copy is frame-exact there and nowhere else (ADR-0008).
///
/// The open/closed-GOP distinction is invisible in packet flags, but it shows up in
/// the timing the index already carries: an *open* keyframe is followed by **leading
/// pictures** — frames that present before it (smaller presentation index) yet decode
/// after it (larger DTS). A copy cut at such a keyframe drops or duplicates those
/// frames; a keyframe with none cuts frame-exact. This was verified in the shell
/// against H.264/MP4, HEVC/MKV and MPEG-2/TS (ADR-0008), and needs no extra ffmpeg
/// pass — it reads only the per-frame DTS, which matters on multi-hour files (ADR-0006).
enum CleanCutDetector {
    /// A presentation-order flag (parallel to `FrameIndex`) marking the clean cut
    /// points among the keyframes.
    ///
    /// - `mpeg2video` is special-cased to **every** keyframe: its leading B-frames
    ///   reference the *previous* GOP, which a kept segment retains, so even open GOPs
    ///   cut frame-exact — the leading-picture test below would needlessly over-flag it.
    /// - Every other codec uses the leading-picture test. It is safe by construction:
    ///   a keyframe with no leading pictures always copy-cuts cleanly, and one that has
    ///   them is excluded. A `nil`/unknown codec uses the same conservative test.
    static func cleanCutFlags(keyframeFlags: [Bool], dts: [Double], codec: String?) -> [Bool] {
        if codec == "mpeg2video" { return keyframeFlags }

        var flags = Array(repeating: false, count: keyframeFlags.count)
        // Running max of every earlier-presented frame's DTS. A keyframe is clean when
        // nothing presented before it decodes later than it does.
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
