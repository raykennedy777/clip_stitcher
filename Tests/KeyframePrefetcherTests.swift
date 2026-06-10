import Testing
import Foundation
@testable import VidConform

/// Pins the pure halves of the keyframe prefetch (issue #34): which keyframes get
/// warmed around a landing (nearest first, alternating directions, bounded), and the
/// keyframe cache's LRU bound.
struct KeyframePrefetcherTests {
    // MARK: neighborhood

    private let keyframes = Array(stride(from: 0, through: 2000, by: 100))   // 21 keyframes

    @Test func neighborhoodStartsAtTheAnchorAndAlternatesNearestFirst() {
        let wanted = KeyframePrefetcher.neighborhood(position: 10, keyframes: keyframes, cap: 5)
        #expect(wanted == [1000, 1100, 900, 1200, 800])
    }

    @Test func neighborhoodIsBoundedByTheCap() {
        let wanted = KeyframePrefetcher.neighborhood(position: 10, keyframes: keyframes, cap: 16)
        #expect(wanted.count == 16)
        #expect(Set(wanted).count == 16)
    }

    @Test func neighborhoodClipsAtTheFileEdges() {
        let atStart = KeyframePrefetcher.neighborhood(position: 0, keyframes: keyframes, cap: 5)
        #expect(atStart == [0, 100, 200, 300, 400])
        let atEnd = KeyframePrefetcher.neighborhood(position: 20, keyframes: keyframes, cap: 5)
        #expect(atEnd == [2000, 1900, 1800, 1700, 1600])
    }

    @Test func neighborhoodOfATinyFileIsJustItsKeyframes() {
        let wanted = KeyframePrefetcher.neighborhood(position: 0, keyframes: [0, 50], cap: 16)
        #expect(wanted == [0, 50])
    }

    @Test func neighborhoodOutOfRangeIsEmpty() {
        #expect(KeyframePrefetcher.neighborhood(position: 99, keyframes: keyframes, cap: 5).isEmpty)
        #expect(KeyframePrefetcher.neighborhood(position: 0, keyframes: [], cap: 5).isEmpty)
    }

    // MARK: bounded LRU

    @Test func lruEvictsTheLeastRecentlyUsedAtCapacity() {
        var lru = BoundedLRU<String>(capacity: 2)
        lru.insert("a", at: 1)
        lru.insert("b", at: 2)
        #expect(lru.value(at: 1) == "a")   // refreshes 1 — 2 is now oldest
        lru.insert("c", at: 3)
        #expect(lru.count == 2)
        #expect(lru.contains(1))
        #expect(!lru.contains(2))
        #expect(lru.value(at: 3) == "c")
    }

    @Test func lruReinsertionUpdatesWithoutEvicting() {
        var lru = BoundedLRU<String>(capacity: 2)
        lru.insert("a", at: 1)
        lru.insert("b", at: 2)
        lru.insert("a2", at: 1)
        #expect(lru.count == 2)
        #expect(lru.value(at: 1) == "a2")
        #expect(lru.contains(2))
    }

    @Test func containsDoesNotRefreshRecency() {
        var lru = BoundedLRU<String>(capacity: 2)
        lru.insert("a", at: 1)
        lru.insert("b", at: 2)
        _ = lru.contains(1)                // a peek, not a use — 1 stays oldest
        lru.insert("c", at: 3)
        #expect(!lru.contains(1))
        #expect(lru.contains(2))
    }
}
