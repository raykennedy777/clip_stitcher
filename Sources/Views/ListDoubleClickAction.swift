import AppKit
import SwiftUI

/// Wires the enclosing List's underlying `NSTableView.doubleAction` so a
/// double-click invokes `action(row)` via AppKit's native mechanism — which does
/// not interfere with single-click selection or the focused highlight at all
/// (unlike a SwiftUI `.onTapGesture`, which swallows the selection click).
///
/// Place as a `.background` on each List **row** — a row's backing view is a
/// genuine descendant of the `NSTableView`, so walking *up* reliably finds the
/// detail table (and never the sidebar's). `action` receives the double-clicked
/// row index.
struct ListDoubleClickAction: NSViewRepresentable {
    let action: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.action = action
        DispatchQueue.main.async { context.coordinator.bindIfNeeded(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
        DispatchQueue.main.async { context.coordinator.bindIfNeeded(from: nsView) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var action: (Int) -> Void = { _ in }
        private weak var tableView: NSTableView?

        func bindIfNeeded(from view: NSView) {
            guard let table = tableView ?? Self.enclosingTableView(of: view) else { return }
            // Reaffirm each update so a surviving row keeps the table's (weak) target
            // valid even after the originally-binding row is removed.
            tableView = table
            table.target = self
            table.doubleAction = #selector(handleDoubleClick)
        }

        private static func enclosingTableView(of view: NSView) -> NSTableView? {
            var ancestor: NSView? = view.superview
            while let current = ancestor {
                if let table = current as? NSTableView { return table }
                if let scroll = current as? NSScrollView,
                   let table = scroll.documentView as? NSTableView { return table }
                ancestor = current.superview
            }
            return nil
        }

        @objc private func handleDoubleClick() {
            guard let table = tableView, table.clickedRow >= 0 else { return }
            action(table.clickedRow)
        }
    }
}
