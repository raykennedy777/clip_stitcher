import Foundation

/// The encoder selection shared by the two re-encode paths: which ffmpeg video encoder
/// an ffprobe `codec_name` re-encodes with, the `-profile:v` token for a probed profile
/// string, and the level tokens. The boundary re-encode engine matches the *source*
/// with these (ADR-0009); the conform engine pins the *target* spec (ADR-0011). One
/// table each, so the two can't drift — the consolidation the conform engine's old
/// `TODO(consolidate)` asked for.
enum EncoderSelection {
    /// The ffmpeg video encoder for a codec_name: HEVC re-encodes with libx265, MPEG-2
    /// with mpeg2video, and everything else — H.264 and any codec without its own
    /// entry — with libx264.
    static func encoder(for codec: String?) -> String {
        switch codec {
        case "hevc": return "libx265"
        case "mpeg2video": return "mpeg2video"
        default: return "libx264"
        }
    }

    /// The codec whose profile table applies to a source codec_name: a codec with its
    /// own encoder entry maps to itself; everything else re-encodes as H.264 (see
    /// `encoder(for:)`), so its profile is looked up in the H.264 table.
    static func profileCodec(for codec: String?) -> String {
        switch codec {
        case "hevc", "mpeg2video": return codec!
        default: return "h264"
        }
    }

    /// Maps an ffprobe `profile` string to the `-profile:v` token its re-encode encoder
    /// expects, for the profiles seen in this domain (broadcast/sports H.264, HEVC, and
    /// MPEG-2). Returns `nil` for an unrecognised profile — the caller then omits
    /// `-profile:v` and lets the encoder infer one from the pixel format, which matches
    /// the source for every common case (verified). Never guesses: a wrong token would
    /// abort the encode.
    static func encoderProfile(_ profile: String?, codec: String) -> String? {
        guard let profile else { return nil }
        switch codec {
        case "h264":
            return [
                "Constrained Baseline": "baseline", "Baseline": "baseline", "Main": "main",
                "High": "high", "High 10": "high10", "High 4:2:2": "high422",
                "High 4:4:4 Predictive": "high444",
            ][profile]
        case "hevc":
            return [
                "Main": "main", "Main 10": "main10", "Main 12": "main12",
                "Main Still Picture": "mainstillpicture",
            ][profile]
        case "mpeg2video":
            return [
                "Simple": "simple", "Main": "main", "High": "high", "4:2:2": "422",
            ][profile]
        default:
            return nil
        }
    }

    /// The deepest reorder depth this app's encoders can produce: x264's and x265's
    /// B-pyramid shuffles the decode order by at most two frames (ADR-0026). A copy piece
    /// from a source deeper than this can't be matched by a re-encode — the export warns
    /// instead of shipping a join it can't keep readable (`ExportPlanner.reorderDepthWarning`).
    static let deepestEncodableReorderDepth = 2

    /// The encoder-params entries that make a re-encoded piece's **reorder depth** match
    /// `depth` — the depth every piece of one Matroska join must agree on (ADR-0026):
    /// `b-pyramid=0` for a shallow (≤ 1) join, nothing for a deeper one, where the
    /// encoders' default pyramid already produces depth 2. Empty for MPEG-2, whose
    /// B-frames never reference other B-frames — it has no pyramid to switch off and is
    /// always depth 1.
    ///
    /// Why depth has to be matched at all: Matroska stores no DTS, so a joined MKV's
    /// reorder depth is whatever the demuxer latches from the **first** piece when it
    /// opens the file. A later piece that needs a deeper one is then read with
    /// non-monotonic DTS — the next stream-copy mux (the audio rebuild) bumps those DTS
    /// forward and drags the PTS onto duplicates — and its frames are emitted early, so
    /// content lands on the wrong timestamps. Measured on real 1080p50 HEVC: a depth-1
    /// conform piece followed by a depth-2 re-encode gave 220 duplicated PTS in 1100
    /// frames, and the same shape with a *copy* piece 71 in 400 (issue #106). Flattening
    /// everything to depth 1 is not the fix: a copy piece keeps its source's depth, so a
    /// deep source with a shallow re-encoded head breaks the other way.
    static func reorderDepthParams(depth: Int, forCodec codec: String?) -> [String] {
        guard codec != "mpeg2video", depth <= 1 else { return [] }
        return ["b-pyramid=0"]
    }

    /// `entries` as the codec's encoder-params flag (`-x264-params`/`-x265-params`) — no
    /// args at all when there is nothing to carry, or for MPEG-2, which has neither flag.
    static func encoderParams(_ entries: [String], forCodec codec: String?) -> [String] {
        withEncoderParams(entries, in: [], forCodec: codec)
    }

    /// `entries` carried on the codec's encoder-params flag (`-x264-params`/`-x265-params`),
    /// merged into an existing occurrence of that flag in `args` rather than added twice —
    /// ffmpeg takes only the last one, so a second flag would silently drop the first
    /// (Clip Doctor's MBAFF repair args carry their own). No args when there is nothing to
    /// carry, and none for MPEG-2, which has neither flag.
    static func withEncoderParams(_ entries: [String], in args: [String], forCodec codec: String?) -> [String] {
        guard !entries.isEmpty, codec != "mpeg2video" else { return args }
        let flag = codec == "hevc" ? "-x265-params" : "-x264-params"
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else {
            return args + [flag, entries.joined(separator: ":")]
        }
        var merged = args
        merged[i + 1] = ([args[i + 1]] + entries).joined(separator: ":")
        return merged
    }

    /// libx264 `-level` token from the probed integer level (e.g. 40 → "4.0", 41 → "4.1").
    static func h264Level(_ level: String?) -> String? {
        guard let n = level.flatMap(Int.init) else { return nil }
        return "\(n / 10).\(n % 10)"
    }

    /// x265 `level-idc` token from HEVC's probed `level` (`general_level_idc` =
    /// level × 30, e.g. 123 → "4.1"); nil when the level is missing or non-integer.
    static func hevcLevel(_ level: String?) -> String? {
        guard let n = level.flatMap(Int.init) else { return nil }
        return "\(n / 30).\((n % 30) / 3)"
    }
}
