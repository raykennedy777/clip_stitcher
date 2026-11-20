import Foundation

enum BoundedExcerpt {
    static func bounded(_ text: String, head: Int = 5, tail: Int = 10) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > head + tail else { return text }
        let omitted = lines.count - head - tail
        return (lines.prefix(head) + ["… \(omitted) more lines …"] + lines.suffix(tail))
            .joined(separator: "\n")
    }
}
