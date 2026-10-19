import XCTest
import SwiftUI
import WebKit
@testable import Luna

/// Drives the real horizontal tab strip with synthesized mouse events.
@MainActor
final class TabStripDragTests: XCTestCase {
    private var store: WorkspaceStore!
    private var window: NSWindow!
    private var split: (UUID, UUID)?
    private var tornOff: (UUID, CGPoint)?

    override func setUp() {
        store = WorkspaceStore(persistence: nil)
        split = nil
        tornOff = nil
    }

    override func tearDown() {
        window?.close()
        window = nil
    }

    private func url(_ s: String) -> URL { URL(string: "https://\(s).com")! }

    private func show() {
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        let strip = HorizontalTabStrip(
            store: store, web: web,
            onActivate: { [unowned self] in store.activate($0) },
            onClose: { [unowned self] in store.close($0) },
            onNewTab: {},
            onSplit: { [unowned self] in split = ($0, $1) },
            onTearOff: { [unowned self] in tornOff = ($0, $1) }
        )
        .frame(width: 600, height: 30)
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: strip)
        host.sizingOptions = []  // keep the window's size; the strip sits in the middle
        window.contentView = host
        window.orderFront(nil)
        spin()
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Tab press views in visual (left-to-right) order, with their window frames.
    private func pressViews() -> [(TabPressNSView, NSRect)] {
        func collect(_ v: NSView) -> [TabPressNSView] {
            (v as? TabPressNSView).map { [$0] } ?? v.subviews.flatMap(collect)
        }
        return collect(window.contentView!)
            .map { ($0, $0.convert($0.bounds, to: nil)) }
            .sorted { $0.1.minX < $1.1.minX }
    }

    private func send(_ type: NSEvent.EventType, _ p: NSPoint) {
        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        window.sendEvent(e)
        spin(0.03)
    }

    private func drag(from a: NSPoint, to b: NSPoint, steps: Int = 12) {
        send(.leftMouseDown, a)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            send(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        send(.leftMouseUp, b)
        spin()
    }

    func testPressingATabNeverMovesTheWindow() {
        _ = (0..<3).map { store.newTab(url: url("t\($0)")) }
        show()
        let views = pressViews()
        XCTAssertEqual(views.count, 3)
        for (view, frame) in views {
            XCTAssertFalse(view.mouseDownCanMoveWindow)
            let hit = window.contentView!.hitTest(NSPoint(x: frame.minX + 12, y: frame.midY))
            XCTAssertTrue(hit === view, "a tab's press view should receive the click")
        }
    }

    func testClickSelectsAndDragReordersLive() {
        let ids = (0..<3).map { store.newTab(url: url("t\($0)")) }
        show()
        var views = pressViews()
        // Click the first tab.
        let first = views[0].1
        send(.leftMouseDown, NSPoint(x: first.minX + 12, y: first.midY))
        send(.leftMouseUp, NSPoint(x: first.minX + 12, y: first.midY))
        XCTAssertEqual(store.activeTabId, ids[0])

        // Drag it past the last tab's middle: it ends up last.
        views = pressViews()
        let start = NSPoint(x: views[0].1.minX + 12, y: views[0].1.midY)
        let end = NSPoint(x: views[2].1.maxX - 4, y: views[2].1.midY)
        let frameBefore = window.frame
        drag(from: start, to: end, steps: 24)
        XCTAssertEqual(store.orderedTabIds, [ids[1], ids[2], ids[0]])
        XCTAssertEqual(window.frame, frameBefore)
        XCTAssertNil(tornOff)
    }

    func testDraggingFarFromTheStripTearsTheTabOff() {
        let ids = (0..<3).map { store.newTab(url: url("t\($0)")) }
        show()
        let v = pressViews()[1].1
        let start = NSPoint(x: v.midX - 20, y: v.midY)
        drag(from: start, to: NSPoint(x: start.x + 30, y: start.y - 90))
        XCTAssertEqual(tornOff?.0, ids[1])
        XCTAssertEqual(store.orderedTabIds, ids, "tearing off doesn't reorder")
    }

    func testDraggingIntoAnotherWindowsStripTargetsTheSlotUnderThePointer() {
        let ids = (0..<3).map { store.newTab(url: url("t\($0)")) }
        show()
        // A second window on the same profile, to the right, with its own strip.
        let otherStore = WorkspaceStore(persistence: nil)
        let otherIds = (0..<2).map { otherStore.newTab(url: url("o\($0)")) }
        let otherStrip = HorizontalTabStrip(
            store: otherStore, web: WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent()),
            onActivate: { _ in }, onClose: { _ in }, onNewTab: {}, onSplit: { _, _ in }
        ).frame(width: 600, height: 30)
        let other = NSWindow(contentRect: NSRect(x: 900, y: 200, width: 600, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: otherStrip)
        host.sizingOptions = []
        other.contentView = host
        // Drops go to the front-most window under the pointer, and the test host's
        // own browser window sits over this spot, so get it out of the way.
        let hostWindows = NSApp.windows.filter { $0.isVisible && $0 !== window }
        hostWindows.forEach { $0.orderOut(nil) }
        other.orderFront(nil)
        defer { other.close(); hostWindows.forEach { $0.orderFront(nil) } }
        let profile = UUID()
        TabDropTargets.shared.register(.init(window: window, profileId: { profile }, adopt: { _, _ in }))
        TabDropTargets.shared.register(.init(window: other, profileId: { profile }, adopt: { _, _ in }))
        spin()

        // Aim between the other window's two tabs, just right of the first one's middle.
        let zone = TabStripDropZone.zone(for: other)!
        let firstOther = zone.frames[otherIds[0]]!
        let stripY = zone.bounds.minY + zone.bounds.height / 2
        let screen = other.convertPoint(toScreen: NSPoint(x: zone.bounds.minX + firstOther.midX + 10,
                                                          y: other.frame.height - stripY))
        let end = window.convertPoint(fromScreen: screen)
        let v = pressViews()[1].1
        let start = NSPoint(x: v.midX - 20, y: v.midY)
        send(.leftMouseDown, start)
        for i in 1...16 {
            let t = CGFloat(i) / 16
            send(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        XCTAssertEqual(zone.markerX, firstOther.maxX, "the other strip marks where the tab will land")
        send(.leftMouseUp, end)
        spin()

        XCTAssertEqual(tornOff?.0, ids[1])
        XCTAssertNil(zone.markerX)
        guard let drop = tornOff?.1 else { return XCTFail("no drop") }
        XCTAssertTrue(TabDropTargets.shared.target(at: drop, from: window)?.window === other)
        let slot = zone.insertion(atScreen: drop)
        XCTAssertEqual(slot?.target, otherIds[0])
        XCTAssertEqual(slot?.after, true)

        otherStore.adopt(Tab(url: url("moved")), nextTo: slot!.target, after: slot!.after)
        XCTAssertEqual(otherStore.orderedTabIds.count, 3)
        XCTAssertEqual(otherStore.orderedTabIds[0], otherIds[0])
        XCTAssertEqual(otherStore.orderedTabIds[2], otherIds[1])
    }

    /// The lifted tab's offset used to feed back into its measured frame, so
    /// dragging past the last tab never settled and froze the app.
    func testDraggingPastTheLastTabSettles() {
        let ids = (0..<3).map { store.newTab(url: url("t\($0)")) }
        show()
        let v = pressViews()[1].1
        drag(from: NSPoint(x: v.midX - 20, y: v.midY), to: NSPoint(x: 580, y: v.midY), steps: 16)
        XCTAssertEqual(store.orderedTabIds, [ids[0], ids[2], ids[1]])
        XCTAssertNil(tornOff)
    }
}
