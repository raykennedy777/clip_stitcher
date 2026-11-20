import Foundation

enum BatchSelection {
    static func canMove(count: Int, selected: Set<Int>, delta: Int) -> Bool {
        guard let top = selected.min(), let bottom = selected.max(),
              top >= 0, bottom < count else { return false }
        return delta < 0 ? top > 0 : bottom < count - 1
    }

    static func movedOrder(count: Int, selected: Set<Int>, delta: Int) -> [Int]? {
        guard canMove(count: count, selected: selected, delta: delta) else { return nil }
        let block = selected.sorted()
        let rest = (0..<count).filter { !selected.contains($0) }
        let blockStart = delta < 0 ? block.first! - 1 : block.last! + 1 - (block.count - 1)
        return Array(rest[..<blockStart]) + block + Array(rest[blockStart...])
    }

    static func duplicateInsertionIndex(selected: Set<Int>) -> Int? {
        selected.max().map { $0 + 1 }
    }

    static func allSameSource(_ keys: [String?]) -> Bool {
        guard let first = keys.first else { return false }
        if keys.count == 1 { return true }
        guard let key = first else { return false }
        return keys.dropFirst().allSatisfy { $0 == key }
    }
}
