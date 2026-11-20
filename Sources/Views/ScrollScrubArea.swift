import SwiftUI

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
        view.onSteps = onSteps
    }
}

final class ScrollCatchView: NSView {
    var onSteps: ((Int, Bool) -> Void)?
    private var accumulator = ScrollScrubAccumulator()
    private var monitor: Any?

    // ADR-0037
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
        let shift = event.modifierFlags.contains(.shift)
        let steps = accumulator.frameSteps(
            deltaY: ScrollScrubAccumulator.effectiveDeltaY(
                deltaY: event.scrollingDeltaY, deltaX: event.scrollingDeltaX,
                precise: event.hasPreciseScrollingDeltas, shift: shift),
            precise: event.hasPreciseScrollingDeltas,
            momentum: event.momentumPhase != [])
        if steps != 0 { onSteps?(steps, shift) }
        return nil
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { removeMonitor() }
}
