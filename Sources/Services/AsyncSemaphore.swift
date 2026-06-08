import Foundation

/// A small FIFO async semaphore for bounding the concurrency of async work — e.g.
/// limiting how many imports probe/scan files at once so bulk-adding many large
/// files doesn't spawn a storm of ffprobe processes.
actor AsyncSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        let bounded = max(1, limit)
        self.limit = bounded
        self.available = bounded
    }

    /// Waits until a slot is free, then claims it. Pair every call with `release()`.
    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Frees a slot, handing it directly to the next waiter if one is queued.
    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available = min(limit, available + 1)
        }
    }
}
