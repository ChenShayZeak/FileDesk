import SwiftUI

extension FileItem {
    var dragProvider: NSItemProvider {
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        provider.suggestedName = name
        return provider
    }
}

// Take the initiating event directly from AppKit so a SwiftUI update cannot lose the drag.
struct FileDragArea: NSViewRepresentable {
    var urls: () -> [URL]
    var click: (NSEvent) -> Void

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.urls = urls
        view.click = click
    }

    final class DragView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        var click: (NSEvent) -> Void = { _ in }
        private var start: NSPoint?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Leave context menus and accessibility to the SwiftUI button underneath.
            if let event = NSApp.currentEvent,
               event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
                return nil
            }
            return super.hitTest(point)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
        }

        override func mouseUp(with event: NSEvent) {
            defer { start = nil }
            if start != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { click(event) }
        }

        override func mouseDragged(with event: NSEvent) {
            let point = event.locationInWindow
            guard let start, hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
            self.start = nil
            let items = Self.draggingItems(for: urls(), at: convert(point, from: nil))
            guard !items.isEmpty else { return }
            beginDraggingSession(with: items, event: event, source: self).draggingFormation = .stack
        }

        static func draggingItems(for urls: [URL], at location: NSPoint) -> [NSDraggingItem] {
            let frame = NSRect(x: location.x - 16, y: location.y - 16, width: 32, height: 32)
            return urls.map { url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                item.draggingFrame = frame
                item.imageComponentsProvider = {
                    let icon = NSDraggingImageComponent(key: .icon)
                    icon.contents = NSWorkspace.shared.icon(forFile: url.path)
                    icon.frame = NSRect(origin: .zero, size: frame.size)
                    return [icon]
                }
                return item
            }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            [.copy, .link, .generic]
        }
    }
}
