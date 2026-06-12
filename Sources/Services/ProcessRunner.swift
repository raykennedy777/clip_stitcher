import Foundation

struct ProcessResult: Sendable {
    var stdout: Data
    var stderr: Data
    var status: Int32
}

/// Runs a bundled command-line tool (ffprobe/ffmpeg) as a subprocess.
///
/// When `stdoutTo` is nil, stdout is captured via a pipe and read in the
/// termination handler — safe only for small output (< ~64 KB pipe buffer), which
/// covers the ffprobe queries and frame-to-file extraction used here. For large
/// output (the frame index dump), pass `stdoutTo` to stream it straight to a file
/// and avoid filling the pipe. The same limit applies to **stderr**: a run whose
/// diagnostics exceed the pipe buffer (a showinfo decode prints one line per
/// frame) deadlocks ffmpeg mid-write — pass `stderrTo` to stream it to a file;
/// the result's `stderr` is then empty.
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
        if let errFileURL {
            FileManager.default.createFile(atPath: errFileURL.path, contents: nil)
            errHandle = try? FileHandle(forWritingTo: errFileURL)
            process.standardError = errHandle
            errPipe = nil
        } else {
            let pipe = Pipe()
            process.standardError = pipe
            errPipe = pipe
            errHandle = nil
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
                    let err = errPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
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
