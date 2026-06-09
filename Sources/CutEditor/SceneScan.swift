import Foundation

/// The cut-editor's scene-change jumps (ROADMAP slice 8): a bounded ffmpeg
/// scene-score scan over a few seconds around the playhead, plus the pure rules
/// for where to land.
///
/// The recipe was de-risked in the shell on all three formats: a full-resolution
/// scan with VideoToolbox hardware decode covers the whole window in ≤0.6s
/// (HEVC 1080p50 worst case; SD MPEG-2/H.264 ≈0.1–0.3s, even deep into a 1.9 GB
/// file). Interlaced sources are deinterlaced first — a cut lands between fields
/// and its score halves otherwise (0.45 vs 0.31 on the same cut). At threshold
/// 0.3, every motion/flash false positive on fast sports footage scored below
/// (≤0.29) while clean camera cuts scored above; soft cuts that slip under it
/// fall back to the cap landing.
enum SceneScan {
    /// Frames whose scene score exceeds this count as scene changes.
    static let threshold = 0.3
    /// How far a scan looks before giving up and landing at the cap.
    static let windowSeconds = 5.0
    /// Lead-in decoded before the window so its first frame has a predecessor to
    /// diff against, and so the imprecise TS / open-GOP seek (which can land a few
    /// frames late) can't swallow the window head. Frames inside the guard never
    /// become landings — the landing rules drop anything outside the window.
    static let guardSeconds = 2.0

    /// ffmpeg arguments for one scan: seek (with guard) to `seekStart`, decode
    /// `duration` seconds, print the pts_time of every frame past the threshold.
    /// `metadata=print` only reaches stdout with an explicit `file=-`.
    ///
    /// `-copyts` makes every reported pts_time the frame's **absolute** stream
    /// timestamp — directly comparable to the frame index. Without it, ffmpeg
    /// re-zeroes timestamps against the *container* start time, which on a file
    /// whose audio starts before its video (the H.264 test clip: container 0.0,
    /// video 0.04) differs from the frame index's video-stream times by exactly
    /// one frame — reconstructing absolute times from the seek request landed
    /// every scene jump one frame late there. `-t` still bounds the decode under
    /// `-copyts` (verified on all three formats).
    static func arguments(inputPath: String, seekStart: Double, duration: Double, deinterlace: Bool) -> [String] {
        let filter = (deinterlace ? "yadif=0," : "")
            + "select='gt(scene,\(threshold))',metadata=print:file=-"
        return [
            "-v", "error", "-nostdin",
            "-hwaccel", "videotoolbox",
            "-copyts",
            "-ss", String(format: "%.6f", seekStart),
            "-t", String(format: "%.6f", duration),
            "-i", inputPath,
            "-an", "-sn",
            "-vf", filter,
            "-f", "null", "-",
        ]
    }

    /// Pulls the `pts_time:` values out of `metadata=print` output (one
    /// `frame:N pts:P pts_time:T` line per selected frame).
    static func parsePTSTimes(_ output: String) -> [Double] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let range = line.range(of: "pts_time:") else { return nil }
            return Double(line[range.upperBound...].prefix(while: { !$0.isWhitespace && $0 != "," }))
        }
    }

    /// The frame whose presentation time is nearest `t` (binary search; `pts` is
    /// ascending).
    static func nearestFrame(toPTS t: Double, in pts: [Double]) -> Int {
        guard !pts.isEmpty else { return 0 }
        var lo = 0
        var hi = pts.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        // `lo` is the first frame at/after `t`; its predecessor may be closer.
        if lo > 0, t - pts[lo - 1] < pts[lo] - t { return lo - 1 }
        return lo
    }

    /// Forward landing: the first scene change after the current frame, or the cap
    /// when the window holds none. Guard/slop frames outside (current, cap] are
    /// ignored.
    static func forwardLanding(sceneFrames: [Int], current: Int, cap: Int) -> Int {
        sceneFrames.filter { $0 > current && $0 <= cap }.min() ?? cap
    }

    /// Backward landing: the last scene change before the current frame, or the
    /// window floor when it holds none.
    static func backwardLanding(sceneFrames: [Int], current: Int, floor: Int) -> Int {
        sceneFrames.filter { $0 < current && $0 >= floor }.max() ?? floor
    }

    /// Runs one scan and maps the reported times back to frame numbers. Thanks to
    /// `-copyts` the reported times are absolute, so each maps straight onto the
    /// frame index — no offset arithmetic. Returns [] on any failure; the caller
    /// then lands at the cap, which is the scan's give-up behavior anyway.
    static func sceneFrames(
        url: URL, seekStart: Double, duration: Double, deinterlace: Bool, pts: [Double]
    ) async -> [Int] {
        guard let ffmpeg = try? FFTools.ffmpegURL() else { return [] }
        let args = arguments(
            inputPath: url.path, seekStart: seekStart, duration: duration, deinterlace: deinterlace)
        guard let result = try? await ProcessRunner.run(ffmpeg, args), result.status == 0 else {
            return []
        }
        let output = String(decoding: result.stdout, as: UTF8.self)
        return parsePTSTimes(output).map { nearestFrame(toPTS: $0, in: pts) }
    }
}
