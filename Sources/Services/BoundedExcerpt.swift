import Foundation

/// Shortens a long multi-line message for a terminal (issue #113). A decode refusal can
/// carry the whole 256 KB stderr tail (issue #59) — thousands of near-identical decoder
/// lines — which buries the first line, the one that names the failure, above the reader's
/// scrollback. The first and last lines hold the signal, so keep those and count the rest.
enum BoundedExcerpt {
    /// The message unchanged when it has `head + tail` lines or fewer; otherwise the first
    /// `head` lines, a `… N more lines …` marker, and the last `tail` lines.
    static func bounded(_ text: String, head: Int = 5, tail: Int = 10) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > head + tail else { return text }
        let omitted = lines.count - head - tail
        return (lines.prefix(head) + ["… \(omitted) more lines …"] + lines.suffix(tail))
            .joined(separator: "\n")
    }
}
