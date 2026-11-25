import SwiftUI

/// Covers the grid document, including the empty space below its last row.
struct GridSelectionArea: NSViewRepresentable {
    let items: [FileItem]
    let columns: Int
    let tileHeight: CGFloat
    let spacing: CGFloat
    let inset: CGFloat
    let accent: Color
    let model: BrowserModel
    let focus: () -> Void

    func makeNSView(context: Context) -> SelectionView { SelectionView() }

    func updateNSView(_ view: SelectionView, context: Context) {
        view.grid = self
    }

    final class SelectionView: NSView {
        var grid: GridSelectionArea?
        private var origin: CGPoint?
        private var rectangle: CGRect?
        private var initialSelection: Set<URL> = []

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // File tiles keep their existing click, drag and context menu handlers.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local), let event = NSApp.currentEvent,
                  event.type == .leftMouseDown, !event.modifierFlags.contains(.control),
                  let grid, !grid.items.isEmpty,
                  indices(in: CGRect(origin: local, size: .zero), grid: grid).isEmpty
            else { return nil }
            return self
        }

        private func indices(in rect: CGRect, grid: GridSelectionArea) -> [Int] {
            let strideY = grid.tileHeight + grid.spacing
            let firstRow = max(0, Int(floor(rect.minY / strideY)))
            let lastRow = min((grid.items.count - 1) / grid.columns, Int(floor(rect.maxY / strideY)))
            guard firstRow <= lastRow else { return [] }
            let width = max(0, (bounds.width - 2 * grid.inset - CGFloat(grid.columns - 1) * grid.spacing) / CGFloat(grid.columns))
            return (firstRow * grid.columns ..< min(grid.items.count, (lastRow + 1) * grid.columns)).filter { index in
                let column = userInterfaceLayoutDirection == .rightToLeft ? grid.columns - 1 - index % grid.columns : index % grid.columns
                let tile = CGRect(x: grid.inset + CGFloat(column) * (width + grid.spacing),
                                  y: CGFloat(index / grid.columns) * strideY, width: width, height: grid.tileHeight)
                return rect.size == .zero ? tile.contains(rect.origin) : tile.intersects(rect)
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let grid else { return }
            grid.focus()
            origin = convert(event.locationInWindow, from: nil)
            initialSelection = event.modifierFlags.isDisjoint(with: [.command, .shift]) ? [] : grid.model.selection
            if grid.model.selection != initialSelection { grid.model.selection = initialSelection }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let grid, let origin else { return }
            autoscroll(with: event)
            let end = convert(event.locationInWindow, from: nil)
            let rect = CGRect(x: min(origin.x, end.x), y: min(origin.y, end.y),
                              width: abs(end.x - origin.x), height: abs(end.y - origin.y))
            rectangle = rect
            needsDisplay = true
            let selection = initialSelection.union(indices(in: rect, grid: grid).map { grid.items[$0].id })
            if grid.model.selection != selection { grid.model.selection = selection }
        }

        override func mouseUp(with event: NSEvent) {
            origin = nil
            rectangle = nil
            initialSelection.removeAll()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let rectangle, let grid else { return }
            let color = NSColor(grid.accent)
            color.withAlphaComponent(0.13).setFill()
            rectangle.fill()
            color.withAlphaComponent(0.75).setStroke()
            NSBezierPath(rect: rectangle).stroke()
        }
    }
}
