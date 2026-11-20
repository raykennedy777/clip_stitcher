import Foundation

struct LineAssembler {
    private var pending = ""

    mutating func feed(_ chunk: String) -> [String] {
        pending += chunk
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        return lines
    }

    mutating func finish() -> String? {
        defer { pending = "" }
        return pending.isEmpty ? nil : pending
    }
}
