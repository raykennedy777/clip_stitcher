import Foundation
import Testing
@testable import ClipStitcher

/// Block-move compaction: the selection moves as one contiguous block, relative
/// order preserved — one position above the topmost selected row (up) or one below
/// the bottommost (down) — issue #12.
struct BatchSelectionMoveTests {
    @Test func nonContiguousSelectionCompactsWhenMovingUp() {
        // [A,B,C,D,E] with B and D selected → block lands above A.
        let order = BatchSelection.movedOrder(count: 5, selected: [1, 3], delta: -1)
        #expect(order == [1, 3, 0, 2, 4])
    }

    @Test func nonContiguousSelectionCompactsWhenMovingDown() {
        // [A,B,C,D,E] with B and D selected → block's last row lands below E's old spot.
        let order = BatchSelection.movedOrder(count: 5, selected: [1, 3], delta: 1)
        #expect(order == [0, 2, 4, 1, 3])
    }

    @Test func contiguousBlockMovesOneStep() {
        #expect(BatchSelection.movedOrder(count: 5, selected: [1, 2], delta: 1) == [0, 3, 1, 2, 4])
        #expect(BatchSelection.movedOrder(count: 5, selected: [1, 2], delta: -1) == [1, 2, 0, 3, 4])
    }

    @Test func singleSelectionDegeneratesToAdjacentSwap() {
        #expect(BatchSelection.movedOrder(count: 4, selected: [2], delta: -1) == [0, 2, 1, 3])
        #expect(BatchSelection.movedOrder(count: 4, selected: [2], delta: 1) == [0, 1, 3, 2])
    }

    @Test func upIsBlockedWhileTheTopmostRowIsFirst() {
        #expect(!BatchSelection.canMove(count: 5, selected: [0, 3], delta: -1))
        #expect(BatchSelection.movedOrder(count: 5, selected: [0, 3], delta: -1) == nil)
        // ...even though other selected rows have room above them.
        #expect(BatchSelection.canMove(count: 5, selected: [0, 3], delta: 1))
    }

    @Test func downIsBlockedWhileTheBottommostRowIsLast() {
        #expect(!BatchSelection.canMove(count: 5, selected: [1, 4], delta: 1))
        #expect(BatchSelection.movedOrder(count: 5, selected: [1, 4], delta: 1) == nil)
        #expect(BatchSelection.canMove(count: 5, selected: [1, 4], delta: -1))
    }

    @Test func selectingEverythingBlocksBothDirections() {
        #expect(!BatchSelection.canMove(count: 3, selected: [0, 1, 2], delta: -1))
        #expect(!BatchSelection.canMove(count: 3, selected: [0, 1, 2], delta: 1))
    }

    @Test func emptySelectionCannotMove() {
        #expect(!BatchSelection.canMove(count: 3, selected: [], delta: -1))
        #expect(BatchSelection.movedOrder(count: 3, selected: [], delta: 1) == nil)
    }
}

struct BatchSelectionDuplicateTests {
    @Test func duplicatesInsertDirectlyBelowTheBottommostSelectedRow() {
        #expect(BatchSelection.duplicateInsertionIndex(selected: [1, 3]) == 4)
        #expect(BatchSelection.duplicateInsertionIndex(selected: [0]) == 1)
    }

    @Test func emptySelectionHasNoInsertionPoint() {
        #expect(BatchSelection.duplicateInsertionIndex(selected: []) == nil)
    }
}

/// "Same source file" = resolved-URL equality (bookmarks for the same file can
/// differ byte-wise) — the caller passes pre-resolved keys, falling back to
/// bookmark bytes only when a missing file's URL can't be resolved at all.
struct BatchSelectionSameSourceTests {
    @Test func identicalKeysGateOpen() {
        #expect(BatchSelection.allSameSource(["url:/a.mp4", "url:/a.mp4", "url:/a.mp4"]))
    }

    @Test func mixedSourcesGateClosed() {
        #expect(!BatchSelection.allSameSource(["url:/a.mp4", "url:/b.mp4"]))
    }

    @Test func aLoneClipAlwaysGatesOpen() {
        // Single-selection behavior predates the gate and stays ungated — even
        // when the lone clip's source can't be identified.
        #expect(BatchSelection.allSameSource(["url:/a.mp4"]))
        #expect(BatchSelection.allSameSource([nil]))
    }

    @Test func unknownSourcesAmongSeveralNeverGateOpen() {
        #expect(!BatchSelection.allSameSource(["url:/a.mp4", nil]))
        #expect(!BatchSelection.allSameSource([nil, nil]))
        #expect(!BatchSelection.allSameSource([]))
    }
}
