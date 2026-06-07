import Foundation

struct ProcessResult: Sendable {
    var stdout: Data
    var stderr: Data
    var status: Int32
}

/// Runs a bundled command-line tool (ffprobe/ffmpeg) as a subprocess.
///
/// NOTE: stdout/stderr are read to end inside the termination handler, which is
/// safe only for tools whose output stays under the pipe buffer (~64 KB) — true
/// for the small ffprobe queries used here. Operations that emit large output
/// (full frame dumps, encoding logs) must stream their pipes instead.
enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ProcessResult(stdout: out, stderr: err, status: proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
