import Foundation
import Testing
@testable import ClipStitcher

struct BatchSelectionMoveTests {
    @Test func nonContiguousSelectionCompactsWhenMovingUp() {
        let order = BatchSelection.movedOrder(count: 5, selected: [1, 3], delta: -1)
        #expect(order == [1, 3, 0, 2, 4])
    }

    @Test func nonContiguousSelectionCompactsWhenMovingDown() {
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

struct BatchSelectionSameSourceTests {
    @Test func identicalKeysGateOpen() {
        #expect(BatchSelection.allSameSource(["url:/a.mp4", "url:/a.mp4", "url:/a.mp4"]))
    }

    @Test func mixedSourcesGateClosed() {
        #expect(!BatchSelection.allSameSource(["url:/a.mp4", "url:/b.mp4"]))
    }

    @Test func aLoneClipAlwaysGatesOpen() {
        #expect(BatchSelection.allSameSource(["url:/a.mp4"]))
        #expect(BatchSelection.allSameSource([nil]))
    }

    @Test func unknownSourcesAmongSeveralNeverGateOpen() {
        #expect(!BatchSelection.allSameSource(["url:/a.mp4", nil]))
        #expect(!BatchSelection.allSameSource([nil, nil]))
        #expect(!BatchSelection.allSameSource([]))
    }
}
