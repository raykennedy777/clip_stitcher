import Testing
import Foundation
@testable import ClipStitcher

struct CancelExportTests {
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

    @Test func aCancelledRunThrowsCancellationErrorNotAResult() async throws {
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
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 3"])
        #expect(result.status == 3)
    }
}
