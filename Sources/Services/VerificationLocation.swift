import Foundation

/// Where a verification refusal happened (issue #113). Every gate that can refuse a piece
/// — the decode check, the frame-count and timestamp checks, the conform acceptance bar —
/// opens its thrown text with this one line, so a reader of a long log knows which clip and
/// which piece failed without reconstructing it from the decoder's output.
///
/// The clip number is the **0-based** index of the clip in the job (`clips[]` in a Stitch
/// Job), which is also the `c<index>_` prefix of the piece file name on the same line.
struct VerificationLocation {
    var clipIndex: Int
    /// The clip's display name; omitted from the line when empty (Clip Doctor and the
    /// engine's own tests can have no name to quote).
    var displayName: String = ""
    /// The piece's file name, not its full path — the work directory is a per-run UUID and
    /// carries no information the reader can act on.
    var piece: String
    /// The segment plan that produced the piece. Empty on a conformed piece, which is one
    /// whole-clip re-encode and has no segment plan.
    var plan: [PlannedSegment] = []
    /// A conformed piece says so in place of a plan summary.
    var conformed: Bool = false

    /// At most this many segments are spelled out; the rest are counted. A long plan must
    /// not turn the location line — which is also the CLI's verdict line — into a wall.
    static let maxPlanSegments = 4

    /// The location line, for example:
    /// `clip 3 “part 4” — piece c3_joined.mkv — plan: reEncode [1234,14682) · copy [14682,56790)`
    var line: String {
        var parts = ["clip \(clipIndex)"]
        if !displayName.isEmpty { parts[0] += " “\(displayName)”" }
        parts.append("piece \(piece)")
        if conformed {
            parts.append("plan: conform")
        } else if !plan.isEmpty {
            parts.append("plan: \(planSummary)")
        }
        return parts.joined(separator: " — ")
    }

    private var planSummary: String {
        let shown = plan.prefix(Self.maxPlanSegments).map { segment -> String in
            let kind = segment.damage.isEmpty ? "\(segment.kind)" : "repair"
            return "\(kind) [\(segment.range.lowerBound),\(segment.range.upperBound))"
        }
        let rest = plan.count - shown.count
        return shown.joined(separator: " · ") + (rest > 0 ? " · +\(rest) more" : "")
    }

    /// The payload of a `verificationFailed`: the location line, then what failed, then the
    /// detail (a decoder tail, a count, a defect) when there is one.
    func message(_ failureLabel: String, detail: String = "") -> String {
        ([line, failureLabel] + (detail.isEmpty ? [] : [detail])).joined(separator: "\n")
    }
}
