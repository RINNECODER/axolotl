// LunaPopover — `.popover` replacement. With Liquid Glass on it is the native
// popover (unchanged look); off, the content sits on a solid raised card in a
// borderless child panel: no arrow, no glass. Closes on outside click and Esc.
import SwiftUI
import AppKit

private final class LunaPopoverPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class LunaPopoverController {
    private let panel: LunaPopoverPanel
    private let host: NSHostingView<AnyView>
    private weak var parentWindow: NSWindow?
    private let anchorRect: NSRect
    private let edge: Edge
    private var monitors: [Any] = []
    private var onClose: (() -> Void)?
    private var isClosed = false
    static let margin: CGFloat = 22

    init(content: AnyView, decorated: Bool, anchorRect: NSRect, edge: Edge, window: NSWindow?, onClose: @escaping () -> Void) {
        let m = Self.margin
        let card: AnyView = decorated
            ? AnyView(content
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LunaSurface.raised))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LunaSurface.stroke))
                .compositingGroup()
                .shadow(color: LunaSurface.shadow, radius: 12, y: 5))
            : content
        host = NSHostingView(rootView: AnyView(card.padding(m)))
        panel = LunaPopoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.contentView = host
        panel.appearance = window?.effectiveAppearance
        self.parentWindow = window
        self.anchorRect = anchorRect
        self.edge = edge
        self.onClose = onClose
        panel.onEscape = { [weak self] in self?.close() }
    }

    func show() {
        layout()
        if let parentWindow { parentWindow.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        // Content can settle (async loads, focus) right after it appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.layout() }
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            guard let self, !self.isClosed else { return event }
            if event.window === self.panel || event.window is LunaMenuPanel { return event }
            self.close()
            return nil
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) { monitors.append(m) }
    }

    private func layout() {
        guard !isClosed else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let m = Self.margin
        let w = size.width - 2 * m, h = size.height - 2 * m
        let screen = (parentWindow?.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var x = anchorRect.midX - w / 2
        var y = edge == .top ? anchorRect.maxY + 6 : anchorRect.minY - 6 - h
        if edge != .top, y < screen.minY { y = anchorRect.maxY + 6 }
        if edge == .top, y + h > screen.maxY { y = anchorRect.minY - 6 - h }
        x = min(max(x, screen.minX + 6), screen.maxX - w - 6)
        panel.setFrame(NSRect(x: x - m, y: y - m, width: size.width, height: size.height), display: true)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        monitors.forEach { NSEvent.removeMonitor($0) }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parentWindow?.makeKey()
        let done = onClose
        onClose = nil
        done?()
    }
}

private struct LunaPopoverModifier<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    var decorated = true
    @ViewBuilder let popover: () -> PopoverContent
    @AppStorage(LiquidGlass.defaultsKey) private var glass = LiquidGlass.defaultValue
    @Environment(\.colorScheme) private var scheme
    @State private var box = LunaAnchorBox()
    @State private var controller: LunaPopoverController?

    func body(content: Content) -> some View {
        if glass {
            content.popover(isPresented: $isPresented, arrowEdge: arrowEdge, content: popover)
        } else {
            content
                .background(LunaAnchorView(box: box))
                .onChange(of: isPresented) { _, open in open ? show() : dismiss() }
                .onAppear { if isPresented { show() } }
                .onDisappear { dismiss() }
        }
    }

    private func show() {
        guard controller == nil, let rect = box.screenRect else { return }
        let c = LunaPopoverController(content: AnyView(popover().environment(\.colorScheme, scheme)),
                                      decorated: decorated, anchorRect: rect, edge: arrowEdge,
                                      window: box.view?.window, onClose: {
            controller = nil
            isPresented = false
        })
        controller = c
        c.show()
    }

    private func dismiss() {
        let c = controller
        controller = nil
        c?.close()
    }
}

extension View {
    /// `.popover` that follows the Liquid Glass setting (native when on, Luna's solid card when off).
    /// `decorated: false` when the content draws its own card.
    func lunaPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .bottom, decorated: Bool = true,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(LunaPopoverModifier(isPresented: isPresented, arrowEdge: arrowEdge, decorated: decorated, popover: content))
    }

    /// Item-driven `lunaPopover`.
    func lunaPopover<Item: Identifiable, Content: View>(item: Binding<Item?>, arrowEdge: Edge = .bottom,
                                                        @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        let shown = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return modifier(LunaPopoverModifier(isPresented: shown, arrowEdge: arrowEdge, popover: {
            if let value = item.wrappedValue { content(value) }
        }))
    }
}
