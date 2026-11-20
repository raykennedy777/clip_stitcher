import Foundation

actor AsyncSemaphore {
    private let limit: Int
    private var available: Int

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    // ADR-0034
    private var waiters: [Waiter] = []
    private var cancelledBeforeRegister: Set<UUID> = []
    private var live: Set<UUID> = []

    init(limit: Int) {
        let bounded = max(1, limit)
        self.limit = bounded
        self.available = bounded
    }

    func acquire() async throws {
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        live.insert(id)
        defer {
            live.remove(id)
            cancelledBeforeRegister.remove(id)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelledBeforeRegister.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            if live.contains(id) { cancelledBeforeRegister.insert(id) }
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            let next = waiters.removeFirst()
            next.continuation.resume()
        }
    }

    #if DEBUG
    var cancelledBeforeRegisterCount: Int { cancelledBeforeRegister.count }
    var liveCount: Int { live.count }
    func simulateCancel(_ id: UUID) { cancelWaiter(id) }
    #endif
}
