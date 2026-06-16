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
