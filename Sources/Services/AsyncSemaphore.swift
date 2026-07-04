import Foundation

/// A small FIFO async semaphore for bounding the concurrency of async work — e.g.
/// limiting how many imports probe/scan files at once so bulk-adding many large
/// files doesn't spawn a storm of ffprobe processes.
actor AsyncSemaphore {
    private let limit: Int
    private var available: Int

    /// A parked acquirer plus the identity a cancellation uses to find *its own*
    /// continuation. The array preserves arrival order (FIFO).
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    /// IDs whose cancellation was observed *before* their continuation registered: the
    /// cancel handler runs off-actor and can win the race to hop back on. The registering
    /// body consumes the flag and resumes-throwing instead of parking — otherwise a
    /// cancel that arrives in that window would be lost and the waiter would suspend forever.
    private var cancelledBeforeRegister: Set<UUID> = []

    init(limit: Int) {
        let bounded = max(1, limit)
        self.limit = bounded
        self.available = bounded
    }

    /// Waits until a slot is free, then claims it. Pair every call that returns
    /// *normally* with `release()`.
    ///
    /// Cancellation-aware: a waiter cancelled while parked resumes by throwing
    /// `CancellationError` and never keeps a slot. Before this the cancelled waiter's
    /// continuation stayed parked forever, leaking that slot — every later `release()`
    /// fed the dead waiter instead of a live one and the throttle wedged. A call that
    /// returns normally *did* claim a slot (even if the task is now cancelled) and must
    /// still be balanced by `release()`; only a thrown `CancellationError` means no slot
    /// was taken.
    func acquire() async throws {
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // If the cancel handler already fired for this id, don't park — resume
                // throwing now (single resume: the handler only recorded the flag, it
                // never touched this continuation, which didn't exist yet).
                if cancelledBeforeRegister.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            // Runs off the actor (any thread, possibly before the body above registers),
            // so hop back on to mutate state under isolation.
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Resumes a parked waiter with `CancellationError`, or — when its continuation hasn't
    /// registered yet — records the cancellation for the registering body to honor. Runs
    /// under actor isolation and removes the waiter from `waiters` before resuming it, so a
    /// `release()` racing on the same actor can never resume the same continuation twice.
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            cancelledBeforeRegister.insert(id)
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Frees a slot, handing it directly to the next waiter if one is queued.
    func release() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            let next = waiters.removeFirst()
            next.continuation.resume()
        }
    }
}
