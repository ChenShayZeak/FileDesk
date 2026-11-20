import AppKit

// A native session gives each selected file its own pasteboard item on macOS 14 and later.
@MainActor
final class GridFileDrag: NSObject, NSDraggingSource {
    private var active = false

    func begin(urls: [URL]) {
        guard !active, let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              let view = event.window?.contentView else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
        let items = urls.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        active = true
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .stack
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        active = false
    }
}
