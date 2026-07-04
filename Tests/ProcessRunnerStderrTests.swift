import Testing
import Foundation
@testable import ClipStitcher

/// Pins `ProcessRunner`'s stderr handling (issue #59): a subprocess that floods stderr
/// past the OS pipe buffer (~64 KB) before exiting must not deadlock, and the result's
/// `stderr` must be a bounded recent tail that still carries the final fatal lines.
/// Before the fix, stderr was read only in the termination handler — so any run writing
/// more than the pipe buffer blocked mid-write and never terminated (the 0%-CPU freeze
/// that stalled the 4.8 h PAFF repair, which ran with live stdout streaming — see the
/// dual-handler test below). These use `/bin/sh`, no ffmpeg bundle.
struct ProcessRunnerStderrTests {
    private static let sh = URL(fileURLWithPath: "/bin/sh")

    /// A `@Sendable` sink for the streamed stdout chunks, which arrive on a FileHandle queue.
    private final class ChunkSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
    }

    @Test func aStderrFloodDoesNotDeadlockAndKeepsABoundedTail() async throws {
        // ~2 MB to stderr (far past the ~64 KB pipe buffer and past the tail's 2× trim
        // threshold), then a unique final marker, then a non-zero exit.
        let run = Task<ProcessResult, Error> {
            try await ProcessRunner.run(Self.sh, ["-c",
                "yes 'mmco discardable ref warning padding line' | head -c 2000000 1>&2; "
                + "printf 'FATAL_TAIL_MARKER_42\\n' 1>&2; exit 7"])
        }
        // With the pre-fix read-at-termination path this run blocks forever. Race it
        // against a generous timeout so a regression fails the test (by cancelling the
        // run, which throws) instead of hanging the whole suite.
        let timeout = Task { try? await Task.sleep(nanoseconds: 20_000_000_000); run.cancel() }
        let result = try await run.value
        timeout.cancel()

        #expect(result.status == 7)
        let text = String(data: result.stderr, encoding: .utf8) ?? ""
        #expect(text.contains("FATAL_TAIL_MARKER_42"))   // the final fatal line survives the trim
        #expect(!result.stderr.isEmpty)
        // Bounded: 2 MB was written but only a recent tail is retained (cap 256 KB, trimmed
        // back once it passes 2× → never exceeds ~512 KB plus one residual drain).
        #expect(result.stderr.count < 600_000)
    }

    @Test func aStderrFloodWithLiveStdoutStreamingDoesNotDeadlock() async throws {
        // Mirrors the path that actually froze the 4.8 h repair (ClipDoctorEngine.runFFmpeg):
        // stdout is streamed live via an `onStdout` closure (`-progress pipe:1`) WHILE stderr
        // floods. Both pipes have live readability handlers; stderr must still drain so the
        // subprocess can exit. Emits stdout lines, floods ~2 MB of stderr, then a final marker.
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
        // stdout was streamed to the callback (not captured in the result).
        #expect(result.stdout.isEmpty)
        let out = sink.text
        #expect(out.contains("out_time=0"))
        #expect(out.contains("out_time=done"))
        // stderr tail survives the concurrent flood and keeps the final fatal line, bounded.
        let err = String(data: result.stderr, encoding: .utf8) ?? ""
        #expect(err.contains("FATAL_TAIL_MARKER_42"))
        #expect(result.stderr.count < 600_000)
    }

    @Test func aSmallStderrFailureIsReturnedWhole() async throws {
        // The common small case must still surface its full stderr as the failure detail —
        // the bounded tail only ever drops bytes once the stream is huge.
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

/// `ProcessRunner.run`'s I/O modes and cancellation surfacing — the paths the stderr-tail
/// suite above doesn't touch: redirecting stdout/stderr straight to a file (the large-output
/// and whole-stream-on-disk cases), and turning a cancel-triggered terminate() into a thrown
/// `CancellationError` rather than a bogus success (issue #32). `/bin/sh`, no ffmpeg bundle.
struct ProcessRunnerIOModeTests {
    private static let sh = URL(fileURLWithPath: "/bin/sh")
    private static func tempFile(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pr66-\(UUID().uuidString).\(ext)")
    }

    /// A `@Sendable` byte-accumulating sink for the streamed/tee'd stdout chunks (they arrive on
    /// a FileHandle queue), snapshotting the total received length.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// `stdoutTo` streams stdout straight to the file; the result's in-memory `stdout` is
    /// then empty (the data lives on disk).
    @Test func stdoutToRedirectsToTheFileLeavingResultStdoutEmpty() async throws {
        let out = Self.tempFile("txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try await ProcessRunner.run(
            Self.sh, ["-c", "printf 'hello stdout\\n'"], stdoutTo: out)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello stdout\n")
    }

    /// `stdoutTo` is the large-output path: it streams to disk, so it captures far more than
    /// the ~64 KB pipe buffer the default in-termination capture is limited to (the frame
    /// index dump's reason for existing). 200 KB lands whole.
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

    /// `stderrTo` writes the **whole** stderr stream to the file (unlike the bounded in-memory
    /// tail) — the path `DamageDetector` uses to parse a per-frame `showinfo` dump. The result's
    /// in-memory `stderr` is then empty, and a 400 KB stream lands whole (not trimmed to 256 KB).
    @Test func stderrToWritesTheWholeUnboundedStreamToTheFile() async throws {
        let err = Self.tempFile("txt")
        defer { try? FileManager.default.removeItem(at: err) }
        let result = try await ProcessRunner.run(
            Self.sh, ["-c", "yes 'showinfo per-frame line' | head -c 400000 1>&2; exit 5"],
            stderrTo: err)
        #expect(result.status == 5)
        #expect(result.stderr.isEmpty)   // file mode bypasses the in-memory tail
        let size = try FileManager.default.attributesOfItem(atPath: err.path)[.size] as? Int
        #expect(size == 400000)          // the whole stream, not the 256 KB bounded tail
    }

    /// `stdoutTo` **and** `onStdout` together *tee* stdout (issue #81): the authoritative stream
    /// is written whole to the file while each chunk is also handed to the callback. The file
    /// must land byte-complete — no chunk lost to the termination close (the write-vs-close race
    /// the timeout drain guards against) — and the callback must see the same total. A 300 KB
    /// output forces many chunks past the ~64 KB pipe buffer, so a dropped tail would show.
    @Test func teeWritesTheWholeFileAndAlsoReportsEveryChunk() async throws {
        let out = Self.tempFile("bin")
        defer { try? FileManager.default.removeItem(at: out) }
        let sink = Sink()
        let result = try await ProcessRunner.run(
            Self.sh, ["-c", "yes AAAAAAAA | head -c 300000"], stdoutTo: out,
            onStdout: { sink.append($0) })
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)                 // tee mode: in-memory stdout stays empty
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int
        #expect(size == 300000)                        // the file landed whole, tail included
        #expect(sink.snapshot().count == 300000)       // and the callback saw every byte too
    }

    /// A cancelled run surfaces as `CancellationError`, not as the tool failing: cancelling
    /// the awaiting task terminates the subprocess, and the exit status after terminate() is
    /// indistinguishable from a real error — so `run` rethrows cancellation (issue #32) rather
    /// than returning a bogus `ProcessResult`.
    @Test func aCancelledRunSurfacesAsCancellationNotAToolFailure() async throws {
        let run = Task<ProcessResult, Error> {
            try await ProcessRunner.run(Self.sh, ["-c", "sleep 30"])
        }
        // Let the subprocess actually start before cancelling, so this exercises the
        // terminate()-then-checkCancellation path rather than a pre-launch cancel.
        try await Task.sleep(nanoseconds: 200_000_000)
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
    }
}
