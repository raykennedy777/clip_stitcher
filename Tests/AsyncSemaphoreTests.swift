import Testing
import Foundation
@testable import ClipStitcher

/// The import-throttle semaphore (issue #86): bounding concurrency, and — the fix —
/// cancellation-awareness. A waiter cancelled while parked must resume by throwing and
/// give its slot back; before the fix its continuation stayed parked forever, so every
/// later `release()` fed the dead waiter and the throttle wedged. Tests race a timeout so
/// a regression fails (a thrown cancellation) instead of hanging the whole suite.
struct AsyncSemaphoreTests {

    @Test func acquireAndReleaseBoundConcurrency() async throws {
        let sem = AsyncSemaphore(limit: 2)
        try await sem.acquire()
        try await sem.acquire()               // both slots taken

        // A third acquire must park until a slot frees.
        let third = Task { try await sem.acquire() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await sem.release()                   // hands the slot straight to `third`

        let timeout = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); third.cancel() }
        try await third.value                 // completes, or the timeout cancel fails the test
        timeout.cancel()
    }

    @Test func aCancelledWaiterResumesByThrowing() async throws {
        let sem = AsyncSemaphore(limit: 1)
        try await sem.acquire()               // hold the only slot

        let waiter = Task { try await sem.acquire() }   // parks: no slot free
        try await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    @Test func aCancelledWaiterDoesNotLeakItsSlot() async throws {
        let sem = AsyncSemaphore(limit: 1)
        try await sem.acquire()               // hold the only slot

        let waiter = Task { try await sem.acquire() }   // parks
        try await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        await sem.release()                   // free the held slot

        // The freed slot must be claimable. A leak would have handed it to the dead
        // waiter, so this acquire would block forever — the timeout makes that a failure.
        let claim = Task { try await sem.acquire() }
        let timeout = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); claim.cancel() }
        try await claim.value
        timeout.cancel()
    }
}
