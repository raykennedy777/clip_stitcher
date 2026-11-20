import AppKit
import SwiftUI

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
