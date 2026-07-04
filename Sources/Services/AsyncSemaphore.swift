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
    /// IDs of acquires currently inside their parking window — inserted at the start of the
    /// slow path (before the continuation may register) and removed once the acquire's body
    /// has fully resumed (normally or throwing). `cancelWaiter` only records a cancellation
    /// while the id is still live: once the acquire has resumed and left this set there is no
    /// registering body left to consume the flag, so recording it would leak the id forever —
    /// exactly the bug where `release()` resumes a waiter just before its late cancel handler
    /// lands (the handler found no waiter and grew `cancelledBeforeRegister` without bound).
    private var live: Set<UUID> = []

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
        live.insert(id)
        defer {
            // Runs back on the actor after the awaits complete. Clearing both tracking sets
            // here covers the two interleavings a late `cancelWaiter` can take relative to a
            // normal resume: if it runs *after* this, `live` no longer holds the id so it
            // won't record anything; if it raced *ahead* and inserted the flag just before
            // this ran, removing it here stops the id from stranding in `cancelledBeforeRegister`.
            live.remove(id)
            cancelledBeforeRegister.remove(id)
        }
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
            // No parked waiter: either the body hasn't registered its continuation yet (record
            // the flag for it to honor) or the acquire has already resumed and left `live` (a
            // normal resume that beat this handler — recording anything now would leak the id,
            // since no body remains to consume it).
            if live.contains(id) { cancelledBeforeRegister.insert(id) }
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

    #if DEBUG
    /// Test seam: the count of ids recorded as cancelled-before-register. Must return to
    /// zero after every acquire completes — the invariant the leak fix protects.
    var cancelledBeforeRegisterCount: Int { cancelledBeforeRegister.count }
    /// Test seam: the count of acquires currently in their parking window.
    var liveCount: Int { live.count }
    /// Test seam: drives the off-actor cancellation path directly. The real race (a late
    /// cancel landing after a normal resume) isn't deterministically reproducible, so tests
    /// exercise the invariant that a cancel for a non-live id can't grow the tracking set.
    func simulateCancel(_ id: UUID) { cancelWaiter(id) }
    #endif
}
