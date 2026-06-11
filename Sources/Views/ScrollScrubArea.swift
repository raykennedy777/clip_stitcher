import SwiftUI

/// Scroll-to-scrub event hookup (issue #40): vertical scroll over the modified
/// view steps the playhead — or, with Shift held, strides keyframes — via
/// `ScrollScrubAccumulator`'s step math. SwiftUI has no scroll-wheel modifier,
/// so a transparent backing view installs a local `NSEvent` monitor and claims
/// only the events whose pointer sits inside its own bounds in its own window:
/// the sidebar keeps scrolling, and the jump popover (its own window) wins
/// whenever the pointer is over it.
extension View {
    func scrollScrub(_ onSteps: @escaping (_ steps: Int, _ keyframeStride: Bool) -> Void) -> some View {
        background(ScrollScrubArea(onSteps: onSteps))
    }
}

private struct ScrollScrubArea: NSViewRepresentable {
    let onSteps: (Int, Bool) -> Void

    func makeNSView(context: Context) -> ScrollCatchView {
        let view = ScrollCatchView()
        view.onSteps = onSteps
        return view
    }

    func updateNSView(_ view: ScrollCatchView, context: Context) {
        // Re-bound every render: the closure captures view state (e.g. the
        // popover's staged field text) that must stay current.
        view.onSteps = onSteps
    }
}

final class ScrollCatchView: NSView {
    var onSteps: ((Int, Bool) -> Void)?
    private var accumulator = ScrollScrubAccumulator()
    private var monitor: Any?

    /// Never intercept clicks or drags — this view only listens for scrolls.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
        let steps = accumulator.frameSteps(
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            momentum: event.momentumPhase != [])
        if steps != 0 { onSteps?(steps, event.modifierFlags.contains(.shift)) }
        // Consumed even when no step fired (sub-threshold or momentum), so
        // nothing beneath the scrub area scrolls and coasting dies here.
        return nil
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { removeMonitor() }
}
