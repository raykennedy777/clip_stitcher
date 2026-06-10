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
