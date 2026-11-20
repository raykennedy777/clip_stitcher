import Foundation

struct VerificationLocation {
    var clipIndex: Int
    var displayName: String = ""
    var piece: String
    var plan: [PlannedSegment] = []
    var conformed: Bool = false

    static let maxPlanSegments = 4

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

    func message(_ failureLabel: String, detail: String = "") -> String {
        ([line, failureLabel] + (detail.isEmpty ? [] : [detail])).joined(separator: "\n")
    }
}
