import Foundation

struct ProcessResult: Sendable {
    var stdout: Data
    var stderr: Data
    var status: Int32
}

/// Accumulates a subprocess's stderr while keeping only a bounded recent tail in
/// memory. stderr is *diagnostic*, not data: every callsite that reads the result's
/// `stderr` does so only to report a failure, and a tool writes its fatal summary
/// last — so the final ~256 KB is all anyone needs. Retaining the whole stream would
/// grow unbounded: a damaged multi-hour decode with `-xerror` floods stderr with a
/// per-frame `mmco`/corrupt-packet warning on every frame (issue #59), megabytes of
/// it. (stdout, by contrast, *is* data — `MediaProbe` parses the whole JSON — so it is
/// never bounded; large stdout uses `stdoutTo`/`onStdout` instead.)
///
/// Thread-safe (an `NSLock` guards `buffer`) — though in practice only one reader, the
/// pipe's `readabilityHandler`, appends, and the snapshot runs after it reaches EOF (see
/// `ProcessRunner`). When trimming, the retained tail is realigned to the next line
/// boundary — or, lacking one, the next UTF-8 codepoint boundary — so it begins on a clean
/// boundary rather than mid-byte and stays valid UTF-8 for `String(data:encoding:)`.
/// Trimming only kicks in once the buffer passes twice the cap, amortising the copy across
/// many small writes (so the retained tail is bounded by 2× cap, not cap).
private final class StderrTail: @unchecked Sendable {
    private let cap: Int
    private let lock = NSLock()
    private var buffer = Data()

    init(cap: Int) { self.cap = cap }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        guard buffer.count > cap * 2 else { return }
        buffer = Data(buffer.suffix(cap))              // rebase to a fresh 0-indexed Data
        if let nl = buffer.firstIndex(of: 0x0A) {      // drop the partial leading line
            buffer = Data(buffer[buffer.index(after: nl)...])
        } else if let start = buffer.firstIndex(where: { $0 & 0xC0 != 0x80 }) {
            buffer = Data(buffer[start...])            // no newline: drop leading UTF-8
        }                                              // continuation bytes to a codepoint start
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Runs a bundled command-line tool (ffprobe/ffmpeg) as a subprocess.
///
/// When `stdoutTo` is nil, stdout is captured via a pipe and read in the
/// termination handler — safe only for small output (< ~64 KB pipe buffer), which
/// covers the ffprobe queries and frame-to-file extraction used here. For large
/// output (the frame index dump), pass `stdoutTo` to stream it straight to a file
/// and avoid filling the pipe.
///
/// **stderr** is always drained live (a `readabilityHandler` empties the pipe as the
/// subprocess writes, so it can never back up and deadlock the process mid-write —
/// issue #59) and the result's `stderr` carries a bounded recent tail (see
/// `StderrTail`). That handler is the *sole* reader and signals EOF; the termination
/// handler waits for it before snapshotting, so the final fatal line can't be lost to a
/// second reader racing the drain. Pass `stderrTo` when a callsite needs the *whole*
/// stderr stream on disk to parse it (e.g. `DamageDetector` reads a per-frame `showinfo`
/// dump); the result's in-memory `stderr` is then empty.
///
/// `onStdout` streams stdout incrementally instead (ffmpeg `-progress pipe:1`,
/// issue #9): each chunk arrives on a FileHandle queue as the subprocess writes —
/// the callback must be thread-safe, and around termination chunk *order* isn't
/// guaranteed either (the tail drain can race a last in-flight read) — and the
/// result's `stdout` is then empty.
enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String], stdoutTo fileURL: URL? = nil,
                    stderrTo errFileURL: URL? = nil,
                    onStdout: (@Sendable (Data) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let errPipe: Pipe?
        let errHandle: FileHandle?
        let errTail: StderrTail?
        let errDone: DispatchSemaphore?
        if let errFileURL {
            FileManager.default.createFile(atPath: errFileURL.path, contents: nil)
            errHandle = try? FileHandle(forWritingTo: errFileURL)
            process.standardError = errHandle
            errPipe = nil
            errTail = nil
            errDone = nil
        } else {
            let pipe = Pipe()
            process.standardError = pipe
            errPipe = pipe
            errHandle = nil
            // Drain stderr live into a bounded tail so the pipe never fills and blocks the
            // subprocess mid-write (issue #59) — the deadlock that froze the 4.8 h PAFF
            // repair. This handler is the sole reader; it signals `done` once it sees EOF
            // (the exited child's write end closing), and the termination handler waits on
            // that before snapshotting — so no second read races the drain for the tail.
            let tail = StderrTail(cap: 256 * 1024)
            let done = DispatchSemaphore(value: 0)
            errTail = tail
            errDone = done
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {            // EOF — write end closed; stop observing
                    handle.readabilityHandler = nil
                    done.signal()
                } else {
                    tail.append(chunk)
                }
            }
        }

        let outHandle: FileHandle?
        let outPipe: Pipe?
        if let fileURL {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            outHandle = try? FileHandle(forWritingTo: fileURL)
            process.standardOutput = outHandle
            outPipe = nil
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            outHandle = nil
            outPipe = pipe
            if let onStdout {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {            // EOF — stop observing
                        handle.readabilityHandler = nil
                    } else {
                        onStdout(chunk)
                    }
                }
            }
        }

        // Terminate the subprocess if the awaiting task is cancelled (e.g. a newer
        // frame seek supersedes this one, or the user cancels an export) so ffmpeg
        // processes don't pile up.
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { proc in
                    var err = Data()
                    if let errPipe {
                        // Wait for the live drain to reach EOF so the tail is complete, then
                        // snapshot it (the recent tail — the final fatal lines). EOF arrives
                        // as soon as the exited child's write end closes; the timeout is a
                        // belt-and-suspenders backstop so a termination can never hang here.
                        if errDone?.wait(timeout: .now() + 5) == .timedOut {
                            errPipe.fileHandleForReading.readabilityHandler = nil
                        }
                        err = errTail?.snapshot() ?? Data()
                    }
                    try? errHandle?.close()
                    var out = Data()
                    if let outPipe {
                        if let onStdout {
                            // Streaming mode: hand any unread tail to the callback.
                            outPipe.fileHandleForReading.readabilityHandler = nil
                            let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
                            if !rest.isEmpty { onStdout(rest) }
                        } else {
                            out = outPipe.fileHandleForReading.readDataToEndOfFile()
                        }
                    }
                    try? outHandle?.close()
                    continuation.resume(returning: ProcessResult(stdout: out, stderr: err, status: proc.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        // A cancel-caused termination must surface as cancellation, not as the tool
        // failing — the exit status after terminate() is indistinguishable from a real
        // error, so the discrimination happens here (issue #32).
        try Task.checkCancellation()
        return result
    }
}
