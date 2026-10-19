import AppKit
import SwiftUI

/// Mouse handling for a tab in the horizontal strip, done in AppKit.
///
/// The strip lives in the window's title-bar area, where a mouse-down on
/// ordinary content starts moving the window before any SwiftUI gesture can
/// recognize. This view claims the press (`mouseDownCanMoveWindow == false`),
/// turns it into a click or a drag, and reports drag positions in window and
/// screen coordinates, so a drag keeps tracking outside the strip and even
/// outside the window (tear-off).
struct TabPressView: NSViewRepresentable {
    struct Drag {
        /// Pointer in the window, top-left origin of the window frame (SwiftUI `.global`).
        var windowPoint: CGPoint
        /// Pointer on screen (AppKit coordinates, bottom-left origin).
        var screenPoint: CGPoint
    }

    /// Width at the trailing edge left to SwiftUI (the close button).
    var trailingPassthrough: CGFloat = 0
    var onClick: () -> Void
    var onDragChanged: (Drag) -> Void
    var onDragEnded: (Drag) -> Void

    func makeNSView(context: Context) -> TabPressNSView {
        let view = TabPressNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: TabPressNSView, context: Context) {
        update(view)
    }

    private func update(_ view: TabPressNSView) {
        view.trailingPassthrough = trailingPassthrough
        view.onClick = onClick
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
    }
}

final class TabPressNSView: NSView {
    var trailingPassthrough: CGFloat = 0
    var onClick: () -> Void = {}
    var onDragChanged: (TabPressView.Drag) -> Void = { _ in }
    var onDragEnded: (TabPressView.Drag) -> Void = { _ in }

    private var downPoint: CGPoint?
    private var isDragging = false
    /// Distance the pointer must travel before a press becomes a drag.
    static let dragThreshold: CGFloat = 4

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), hit === self else { return nil }
        // Right-clicks go to SwiftUI's context menu; the close button keeps its clicks.
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            return nil
        }
        let local = convert(point, from: superview)
        if trailingPassthrough > 0, local.x > bounds.maxX - trailingPassthrough { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let p = event.locationInWindow
        if !isDragging, hypot(p.x - start.x, p.y - start.y) < Self.dragThreshold { return }
        if !isDragging {
            isDragging = true
            onDragChanged(drag(at: start, event: event))
        }
        onDragChanged(drag(at: p, event: event))
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil; isDragging = false }
        if isDragging {
            onDragEnded(drag(at: event.locationInWindow, event: event))
        } else if downPoint != nil {
            onClick()
        }
    }

    private func drag(at windowPoint: CGPoint, event: NSEvent) -> TabPressView.Drag {
        // SwiftUI's .global space starts at the window's top edge (title bar included).
        let height = window?.frame.height ?? 0
        let screen = window?.convertPoint(toScreen: windowPoint) ?? windowPoint
        return TabPressView.Drag(windowPoint: CGPoint(x: windowPoint.x, y: height - windowPoint.y), screenPoint: screen)
    }
}
