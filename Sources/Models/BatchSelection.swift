import Foundation

/// Pure math behind the Source view's multi-select batch actions (issue #12):
/// block-move compaction, the duplicate insertion point, and the same-source gate.
/// All row positions are indices into the timeline (the Source view's clip list,
/// in timeline order) — a selection `Set` carries no order of its own.
enum BatchSelection {
    /// Whether the selected rows can move one step up (`delta` -1) or down (+1):
    /// up while the topmost selected row isn't first, down while the bottommost
    /// isn't last.
    static func canMove(count: Int, selected: Set<Int>, delta: Int) -> Bool {
        guard let top = selected.min(), let bottom = selected.max(),
              top >= 0, bottom < count else { return false }
        return delta < 0 ? top > 0 : bottom < count - 1
    }

    /// The new row order (as indices into the current order) after moving the
    /// selection one step up or down, compacting it Finder-style: the selected rows
    /// become one contiguous block in their current relative order, placed one
    /// position above the topmost selected row (up) or one below the bottommost
    /// (down). Nil when the move is blocked at the list edge.
    static func movedOrder(count: Int, selected: Set<Int>, delta: Int) -> [Int]? {
        guard canMove(count: count, selected: selected, delta: delta) else { return nil }
        let block = selected.sorted()
        let rest = (0..<count).filter { !selected.contains($0) }
        // Where the block's first row lands: every row before it is unselected, so
        // this is also how many `rest` rows precede the block.
        let blockStart = delta < 0 ? block.first! - 1 : block.last! + 1 - (block.count - 1)
        return Array(rest[..<blockStart]) + block + Array(rest[blockStart...])
    }

    /// Where duplicates insert: as one contiguous run directly below the bottommost
    /// selected row. Nil for an empty selection.
    static func duplicateInsertionIndex(selected: Set<Int>) -> Int? {
        selected.max().map { $0 + 1 }
    }

    /// The same-source gate (Audio Settings…, Relink…): true when every selected
    /// clip's source key is known and identical. A lone clip trivially shares its
    /// source with itself, so a single selection always gates open (pre-#12
    /// single-selection behavior is unchanged). A nil key — a clip whose source
    /// can't be identified at all — never matches another clip's.
    static func allSameSource(_ keys: [String?]) -> Bool {
        guard let first = keys.first else { return false }
        if keys.count == 1 { return true }
        guard let key = first else { return false }
        return keys.dropFirst().allSatisfy { $0 == key }
    }
}
