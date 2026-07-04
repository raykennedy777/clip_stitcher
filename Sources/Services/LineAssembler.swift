import Foundation

/// Incremental line assembly over the raw text chunks a subprocess streams on stdout
/// (issues #81, #84): a chunk can split a line at any byte, so the trailing partial line
/// is held back until its terminating newline arrives in a later chunk. One splitter
/// shared by the export progress parser (`ExportProgress.Stream`) and the streamed
/// all-streams scan (`FrameIndexer.StreamingAllStreamsScan`) — both the scan's progress
/// signal and its packet parse read the same assembled lines — rather than three copies of
/// the same chunk→line dance.
///
/// Splits on `\n` only: ffprobe/ffmpeg emit LF-terminated lines. Pure, so it's unit-testable.
struct LineAssembler {
    private var pending = ""

    /// Feeds one chunk and returns the newline-terminated lines it completes. The trailing
    /// partial line (everything after the last `\n`) is retained for the next chunk, so a
    /// line split across chunks is reassembled before it's returned. Returning the lines
    /// (rather than invoking a callback) lets the caller mutate its own state per line
    /// without an exclusive-access overlap on the assembler.
    mutating func feed(_ chunk: String) -> [String] {
        pending += chunk
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()      // components always yields ≥1 element
        return lines
    }

    /// Returns any retained final line that never received a terminating newline (a stream
    /// whose last line has no trailing `\n`) and clears the buffer — matching
    /// `String.enumerateLines`, which yields that final line. Call once after EOF.
    mutating func finish() -> String? {
        defer { pending = "" }
        return pending.isEmpty ? nil : pending
    }
}
