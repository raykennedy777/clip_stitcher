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
/// and avoid filling the pipe.
enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String], stdoutTo fileURL: URL? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let errPipe = Pipe()
        process.standardError = errPipe

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
        }

        // Terminate the subprocess if the awaiting task is cancelled (e.g. a newer
        // frame seek supersedes this one) so ffmpeg processes don't pile up.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { proc in
                    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let out = outPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
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
    }
}
