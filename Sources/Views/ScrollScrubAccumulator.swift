import Foundation

struct ScrollScrubAccumulator {
    static let pointsPerFrame: CGFloat = 10

    private var carry: CGFloat = 0

    static func effectiveDeltaY(deltaY: CGFloat, deltaX: CGFloat,
                                precise: Bool, shift: Bool) -> CGFloat {
        if shift, !precise, deltaY == 0 { return deltaX }
        return deltaY
    }

    // ADR-0037
    mutating func frameSteps(deltaY: CGFloat, precise: Bool, momentum: Bool) -> Int {
        guard !momentum, deltaY != 0 else { return 0 }
        if !precise {
            let notches = Int(deltaY.rounded(.awayFromZero))
            return -notches
        }
        carry += deltaY
        let steps = (carry / Self.pointsPerFrame).rounded(.towardZero)
        carry -= steps * Self.pointsPerFrame
        return Int(-steps)
    }
}
