import Foundation

struct ProcessResult: Sendable {
    var stdout: Data
    var stderr: Data
    var status: Int32
}

// ADR-0034
final class StderrTail: @unchecked Sendable {
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
        buffer = Data(buffer.suffix(cap))
        if let nl = buffer.firstIndex(of: 0x0A) {
            buffer = Data(buffer[buffer.index(after: nl)...])
        } else if let start = buffer.firstIndex(where: { $0 & 0xC0 != 0x80 }) {
            buffer = Data(buffer[start...])
        }
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

enum ProcessRunner {
    #if DEBUG
    final class LaunchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func record() { lock.lock(); value += 1; lock.unlock() }
    }
    @TaskLocal static var launchCounter: LaunchCounter?
    #endif

    static func run(_ executable: URL, _ arguments: [String], stdoutTo fileURL: URL? = nil,
                    stderrTo errFileURL: URL? = nil,
                    onStdout: (@Sendable (Data) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // ADR-0034
        process.standardInput = FileHandle.nullDevice

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
            let tail = StderrTail(cap: 256 * 1024)
            let done = DispatchSemaphore(value: 0)
            errTail = tail
            errDone = done
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    done.signal()
                } else {
                    tail.append(chunk)
                }
            }
        }

        let outHandle: FileHandle?
        let outPipe: Pipe?
        let outDone: DispatchSemaphore?
        let teeToFile: Bool
        if let fileURL {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            let handle = try? FileHandle(forWritingTo: fileURL)
            outHandle = handle
            if let onStdout {
                let pipe = Pipe()
                process.standardOutput = pipe
                outPipe = pipe
                teeToFile = true
                let done = DispatchSemaphore(value: 0)
                outDone = done
                pipe.fileHandleForReading.readabilityHandler = { fh in
                    let chunk = fh.availableData
                    if chunk.isEmpty {
                        fh.readabilityHandler = nil
                        done.signal()
                    } else {
                        try? handle?.write(contentsOf: chunk)
                        onStdout(chunk)
                    }
                }
            } else {
                process.standardOutput = handle
                outPipe = nil
                teeToFile = false
                outDone = nil
            }
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            outHandle = nil
            outPipe = pipe
            teeToFile = false
            if let onStdout {
                let done = DispatchSemaphore(value: 0)
                outDone = done
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        done.signal()
                    } else {
                        onStdout(chunk)
                    }
                }
            } else {
                outDone = nil
            }
        }

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { proc in
                    var err = Data()
                    if let errPipe {
                        if errDone?.wait(timeout: .now() + 5) == .timedOut {
                            errPipe.fileHandleForReading.readabilityHandler = nil
                        }
                        err = errTail?.snapshot() ?? Data()
                    }
                    try? errHandle?.close()
                    var out = Data()
                    if let outPipe {
                        if teeToFile {
                            if outDone?.wait(timeout: .now() + 5) == .timedOut {
                                outPipe.fileHandleForReading.readabilityHandler = nil
                                let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
                                if !rest.isEmpty { try? outHandle?.write(contentsOf: rest) }
                            }
                        } else if let onStdout {
                            if outDone?.wait(timeout: .now() + 5) == .timedOut {
                                outPipe.fileHandleForReading.readabilityHandler = nil
                                let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
                                if !rest.isEmpty { onStdout(rest) }
                            }
                        } else {
                            out = outPipe.fileHandleForReading.readDataToEndOfFile()
                        }
                    }
                    try? outHandle?.close()
                    continuation.resume(returning: ProcessResult(stdout: out, stderr: err, status: proc.terminationStatus))
                }
                do {
                    try process.run()
                    #if DEBUG
                    Self.launchCounter?.record()
                    #endif
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        // ADR-0034
        try Task.checkCancellation()
        return result
    }
}
