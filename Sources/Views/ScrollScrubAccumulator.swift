import Foundation

/// Turns scroll-wheel deltas into playhead frame steps (issue #40). Pure step
/// math, kept out of the event-monitor view for testing.
///
/// Direction follows page meaning: positive deltaY — the gesture that scrolls
/// a webpage toward its top — moves the playhead backward. The system-adjusted
/// delta is used as-is, so Natural Scrolling needs no compensation.
struct ScrollScrubAccumulator {
    /// Trackpad points that add up to one frame step. Tuned by feel: small
    /// enough that a slow drag responds, large enough that a frame is a
    /// deliberate nudge rather than a tremor.
    static let pointsPerFrame: CGFloat = 10

    /// Sub-threshold trackpad points carried between events, so slow nudges
    /// add up. Signed: reversing direction unwinds it before stepping back.
    private var carry: CGFloat = 0

    /// The vertical delta to scrub by. macOS re-routes a shifted mouse wheel
    /// onto the horizontal axis before apps see the event (Shift+wheel scrolls
    /// sideways system-wide), so the Shift+scroll keyframe stride would read
    /// an empty vertical delta and do nothing. Under Shift, a wheel event with
    /// no vertical delta falls back to the horizontal one — the same physical
    /// gesture, same sign. Everything else keeps vertical-only semantics:
    /// deltaX is ignored (horizontal scrubbing is an explicit non-goal).
    static func effectiveDeltaY(deltaY: CGFloat, deltaX: CGFloat,
                                precise: Bool, shift: Bool) -> CGFloat {
        if shift, !precise, deltaY == 0 { return deltaX }
        return deltaY
    }

    /// Frame steps for one scroll event; positive = forward in time.
    ///
    /// Mouse wheel (`precise == false`): one notch = one frame, every notch in
    /// a coalesced event counted, and a sub-1.0 driver delta still steps — a
    /// notch must never be swallowed. Trackpad (`precise == true`): points
    /// accumulate toward `pointsPerFrame` with the remainder carried. Momentum
    /// events (coasting after fingers lift) are ignored entirely — the
    /// playhead stops dead, and the carry survives untouched.
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
