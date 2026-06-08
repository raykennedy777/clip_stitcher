import Foundation

/// Milestone 2 export executor (ADR-0009): produces a frame-exact between-keyframes cut
/// by re-encoding the partial head/tail GOPs and stream-copying the keyframe-bounded
/// middle, then concatenating — the recipe validated frame-exact against real
/// H.264/HEVC/MPEG-2 footage in the shell. It executes a `BoundaryReencodePlanner` plan
/// with the bundled ffmpeg CLI only; no in-process libav (ADR-0002).
///
/// The argument builders are pure so the exact command shape can be unit-tested.
enum BoundaryReencodeEngine {
    /// The segment that holds the copied middle: the muxer writes [start, cut1) as
    /// segment 0 and the wanted [cut1, cut2) span as segment 1.
    static let middleSegmentIndex = 1

    /// ffmpeg video-encode args matched to the source so the re-encoded GOPs concat
    /// cleanly with the copied middle (ADR-0009): same codec family and pixel format,
    /// and — for interlaced MPEG-2 — the field flags that preserve `field_order`. SAR is
    /// carried through by ffmpeg automatically, so no `-aspect` is needed (verified).
    static func reencodeVideoArgs(codec: String?, pixelFormat: String?, fieldOrder: String?) -> [String] {
        let pixFmt = pixelFormat ?? "yuv420p"
        switch codec {
        case "hevc":
            return ["-c:v", "libx265", "-pix_fmt", pixFmt]
        case "mpeg2video":
            var args = ["-c:v", "mpeg2video", "-pix_fmt", pixFmt]
            switch fieldOrder {
            case "tt", "tb": args += ["-flags", "+ildct+ilme", "-top", "1"]
            case "bb", "bt": args += ["-flags", "+ildct+ilme", "-top", "0"]
            default: break   // progressive / unknown — no interlace flags
            }
            return args
        default:   // h264 and anything else -> libx264
            return ["-c:v", "libx264", "-pix_fmt", pixFmt]
        }
    }

    /// ffmpeg args to re-encode the partial-GOP presentation range `[range.lowerBound,
    /// range.upperBound)` into `output`. To avoid decoding the whole file, it input-seeks
    /// to the keyframe at/before the range start (which the decoder emits as `n = 0`),
    /// then selects frames RELATIVE to that keyframe. The seek is start_time-relative
    /// (ffmpeg subtracts the stream start_time from `-ss`), so the first presentation PTS
    /// is removed. Audio is dropped here; the rebuilt track is muxed in later.
    static func reencodeSegmentArguments(
        source: URL, range: Range<Int>, index: FrameIndex, encoder: [String], output: URL
    ) -> [String] {
        let anchor = index.keyframeIndex(atOrBefore: range.lowerBound)
        let startOffset = index.pts.first ?? 0
        let seek = index.pts[anchor] - startOffset
        let relStart = range.lowerBound - anchor
        let relEnd = range.upperBound - 1 - anchor
        var args = ["-v", "error", "-ss", ExportEngine.timeString(seek), "-i", source.path]
        args += ["-vf", "select='between(n\\,\(relStart)\\,\(relEnd))',setpts=PTS-STARTPTS"]
        args += encoder
        args += ["-an", output.path]
        return args
    }

    /// ffmpeg args to stream-copy the keyframe-bounded middle `[copyRange.lowerBound,
    /// copyRange.upperBound)` — both ends are copy-safe boundaries. The segment muxer is
    /// cut at each (start_time-corrected DTS midpoints, ADR-0008); the wanted span is
    /// `middleSegmentIndex`. A pure copy, so the middle stays bit-exact.
    static func copyMiddleArguments(
        source: URL, copyRange: Range<Int>, index: FrameIndex, segmentPattern: String
    ) -> [String] {
        let t1 = index.segmentTime(forCutAt: copyRange.lowerBound)
        let t2 = index.segmentTime(forCutAt: copyRange.upperBound)
        return [
            "-v", "error", "-i", source.path, "-map", "0:v:0", "-c", "copy",
            "-f", "segment",
            "-segment_times", "\(ExportEngine.timeString(t1)),\(ExportEngine.timeString(t2))",
            "-reset_timestamps", "1", segmentPattern,
        ]
    }
}
