import Testing
import Foundation
@testable import ClipStitcher

struct AsyncSemaphoreTests {
    @Test func acquireAndReleaseBoundConcurrency() async throws {
        let sem = AsyncSemaphore(limit: 2)
        try await sem.acquire()
        try await sem.acquire()

        let third = Task { try await sem.acquire() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await sem.release()

        let timeout = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); third.cancel() }
        try await third.value
        timeout.cancel()
    }

    @Test func aCancelledWaiterResumesByThrowing() async throws {
        let sem = AsyncSemaphore(limit: 1)
        try await sem.acquire()

        let waiter = Task { try await sem.acquire() }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    @Test func aCancelledWaiterDoesNotLeakItsSlot() async throws {
        let sem = AsyncSemaphore(limit: 1)
        try await sem.acquire()

        let waiter = Task { try await sem.acquire() }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        await sem.release()

        let claim = Task { try await sem.acquire() }
        let timeout = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); claim.cancel() }
        try await claim.value
        timeout.cancel()
    }

    @Test func cancelForANonLiveIdDoesNotGrowTheSet() async {
        let sem = AsyncSemaphore(limit: 1)
        await sem.simulateCancel(UUID())
        await sem.simulateCancel(UUID())
        #expect(await sem.cancelledBeforeRegisterCount == 0)
        #expect(await sem.liveCount == 0)
    }

    @Test func acquireReleaseCycleLeavesTrackingSetsEmpty() async throws {
        let sem = AsyncSemaphore(limit: 1)
        try await sem.acquire()
        await sem.release()

        try await sem.acquire()
        let parked = Task { try await sem.acquire() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await sem.release()
        try await parked.value
        await sem.release()

        #expect(await sem.liveCount == 0)
        #expect(await sem.cancelledBeforeRegisterCount == 0)
    }
}
