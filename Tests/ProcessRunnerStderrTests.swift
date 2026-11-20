import Testing
import Foundation
@testable import ClipStitcher

struct ProcessRunnerStderrTests {
    private static let sh = URL(fileURLWithPath: "/bin/sh")

    private final class ChunkSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
    }

    @Test func aStderrFloodDoesNotDeadlockAndKeepsABoundedTail() async throws {
        let run = Task<ProcessResult, Error> {
            try await ProcessRunner.run(Self.sh, ["-c",
                "yes 'mmco discardable ref warning padding line' | head -c 2000000 1>&2; "
                + "printf 'FATAL_TAIL_MARKER_42\\n' 1>&2; exit 7"])
        }
        let timeout = Task { try? await Task.sleep(nanoseconds: 20_000_000_000); run.cancel() }
        let result = try await run.value
        timeout.cancel()

        #expect(result.status == 7)
        let text = String(data: result.stderr, encoding: .utf8) ?? ""
        #expect(text.contains("FATAL_TAIL_MARKER_42"))
        #expect(!result.stderr.isEmpty)
        #expect(result.stderr.count < 600_000)
    }

    @Test func aStderrFloodWithLiveStdoutStreamingDoesNotDeadlock() async throws {
        let sink = ChunkSink()
        let run = Task<ProcessResult, Error> {
            try await ProcessRunner.run(Self.sh, ["-c",
                "i=0; while [ $i -lt 50 ]; do echo \"out_time=$i\"; i=$((i+1)); done; "
                + "yes 'mmco discardable ref warning padding line' | head -c 2000000 1>&2; "
                + "echo out_time=done; printf 'FATAL_TAIL_MARKER_42\\n' 1>&2; exit 7"],
                onStdout: { sink.append($0) })
        }
        let timeout = Task { try? await Task.sleep(nanoseconds: 20_000_000_000); run.cancel() }
        let result = try await run.value
        timeout.cancel()

        #expect(result.status == 7)
        #expect(result.stdout.isEmpty)
        let out = sink.text
        #expect(out.contains("out_time=0"))
        #expect(out.contains("out_time=done"))
        let err = String(data: result.stderr, encoding: .utf8) ?? ""
        #expect(err.contains("FATAL_TAIL_MARKER_42"))
        #expect(result.stderr.count < 600_000)
    }

    @Test func aSmallStderrFailureIsReturnedWhole() async throws {
        let result = try await ProcessRunner.run(Self.sh, ["-c", "echo 'boom: bad invocation' 1>&2; exit 2"])
        #expect(result.status == 2)
        #expect(String(data: result.stderr, encoding: .utf8) == "boom: bad invocation\n")
    }

    @Test func aCleanRunHasEmptyStderr() async throws {
        let result = try await ProcessRunner.run(Self.sh, ["-c", "exit 0"])
        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
    }
}

struct ProcessRunnerIOModeTests {
    private static let sh = URL(fileURLWithPath: "/bin/sh")
    private static func tempFile(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pr66-\(UUID().uuidString).\(ext)")
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    @Test func stdoutToRedirectsToTheFileLeavingResultStdoutEmpty() async throws {
        let out = Self.tempFile("txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try await ProcessRunner.run(
            Self.sh, ["-c", "printf 'hello stdout\\n'"], stdoutTo: out)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello stdout\n")
    }

    @Test func stdoutToCapturesOutputPastThePipeBuffer() async throws {
        let out = Self.tempFile("bin")
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try await ProcessRunner.run(
            Self.sh, ["-c", "yes AAAAAAAA | head -c 200000"], stdoutTo: out)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int
        #expect(size == 200000)
    }

    @Test func stderrToWritesTheWholeUnboundedStreamToTheFile() async throws {
        let err = Self.tempFile("txt")
        defer { try? FileManager.default.removeItem(at: err) }
        let result = try await ProcessRunner.run(
            Self.sh, ["-c", "yes 'showinfo per-frame line' | head -c 400000 1>&2; exit 5"],
            stderrTo: err)
        #expect(result.status == 5)
        #expect(result.stderr.isEmpty)
        let size = try FileManager.default.attributesOfItem(atPath: err.path)[.size] as? Int
        #expect(size == 400000)
    }

    @Test func teeWritesTheWholeFileAndAlsoReportsEveryChunk() async throws {
        let out = Self.tempFile("bin")
        defer { try? FileManager.default.removeItem(at: out) }
        let sink = Sink()
        let result = try await ProcessRunner.run(
            Self.sh, ["-c", "yes AAAAAAAA | head -c 300000"], stdoutTo: out,
            onStdout: { sink.append($0) })
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int
        #expect(size == 300000)
        #expect(sink.snapshot().count == 300000)
    }

    @Test func aCancelledRunSurfacesAsCancellationNotAToolFailure() async throws {
        let run = Task<ProcessResult, Error> {
            try await ProcessRunner.run(Self.sh, ["-c", "sleep 30"])
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
    }
}

@Suite(.serialized)
struct ProcessRunnerStdinTests {
    @Test func aSubprocessReadsNullNotTheParentsStdin() async throws {
        let pipe = Pipe()
        let savedStdin = dup(0)
        #expect(savedStdin >= 0)
        dup2(pipe.fileHandleForReading.fileDescriptor, 0)
        defer {
            dup2(savedStdin, 0)
            close(savedStdin)
            withExtendedLifetime(pipe) {}
        }

        let run = Task<ProcessResult, Error> {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), [])
        }
        let timeout = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); run.cancel() }
        let result = try await run.value
        timeout.cancel()

        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }
}
