import Testing
import Foundation
@testable import VidConform

/// Pins export cancellation (issue #32): the kept-files accounting on the status
/// detail, and the discrimination between a cancel-caused process termination and a
/// genuine failure — a terminated ffmpeg's exit status looks exactly like an error,
/// so `ProcessRunner` must surface cancellation as `CancellationError` instead.
struct CancelExportTests {
    // MARK: completed-file accounting

    @Test func someFinishedSeparateFilesAreReported() {
        #expect(ProjectDocument.cancelDetail(finished: 3, total: 5) == "3 of 5 files were finished.")
        #expect(ProjectDocument.cancelDetail(finished: 1, total: 2) == "1 of 2 files were finished.")
    }

    @Test func nothingFinishedHasNothingToAdd() {
        #expect(ProjectDocument.cancelDetail(finished: 0, total: 5) == nil)
    }

    @Test func connectModesSingleFileHasNothingToAdd() {
        #expect(ProjectDocument.cancelDetail(finished: 0, total: 1) == nil)
        #expect(ProjectDocument.cancelDetail(finished: 1, total: 1) == nil)
    }

    // MARK: cancelled-vs-failed discrimination

    @Test func aCancelledRunThrowsCancellationErrorNotAResult() async throws {
        // A long-running process, cancelled mid-run: the terminate()-caused exit must
        // come back as CancellationError, never as a ProcessResult a caller would
        // mistake for a real (failed) run.
        let task = Task<String, Error> {
            do {
                let result = try await ProcessRunner.run(
                    URL(fileURLWithPath: "/bin/sleep"), ["30"])
                return "result status \(result.status)"
            } catch is CancellationError {
                return "cancelled"
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let outcome = try await task.value
        #expect(outcome == "cancelled")
    }

    @Test func anUncancelledFailureStillReturnsItsExitStatus() async throws {
        // The discrimination must not swallow genuine failures: a bad invocation on a
        // live (uncancelled) task still reports its non-zero status.
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 3"])
        #expect(result.status == 3)
    }
}
