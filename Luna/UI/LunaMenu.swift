// LunaMenu — Luna's own dropdown / context menu, drawn in a borderless panel
// instead of NSMenu. Styled after Chrome's menu (measured from Chrome 2025 on
// macOS): 28pt rows, icon column on the left, shortcuts and submenu chevrons on
// the right, full-width separators, 12pt corners, a crisp shadow.
//
// Use `LunaMenuButton` for toolbar / sidebar buttons, `.lunaMenu(isPresented:)`
// to open from any view, and `.lunaContextMenu { }` for right-click menus.
import SwiftUI
import AppKit
import Combine

// MARK: - Style

enum LunaMenuFlavor {
    /// Chrome template: Chrome's solid colors, always (Chrome never uses glass).
    case chrome
    /// Luna layouts: Luna's neutrals. Menus stay solid with Liquid Glass on too: glass in a
    /// borderless menu panel samples the panel's own transparent margin and renders clipped.
    case luna
}

private struct LunaMenuFlavorKey: EnvironmentKey { static let defaultValue: LunaMenuFlavor = .luna }

extension EnvironmentValues {
    var lunaMenuFlavor: LunaMenuFlavor {
        get { self[LunaMenuFlavorKey.self] }
        set { self[LunaMenuFlavorKey.self] = newValue }
    }
}

/// Shared visual tokens for every Luna menu and dropdown (LunaMenu, DevDropdown, pickers).
struct LunaMenuStyle {
    var background: Color
    var border: Color
    var hover: Color
    var text: Color
    var secondary: Color
    var separator: Color
    var zoomButton: Color
    var shadow: Color
    var shadowRadius: CGFloat
    var shadowY: CGFloat
    var cornerRadius: CGFloat = 12
    var rowHeight: CGFloat = 28
    var verticalPadding: CGFloat
    var horizontalPadding: CGFloat
    /// Hover fill inset from the menu edges (0 = full-bleed, Chrome).
    var hoverInset: CGFloat
    var hoverRadius: CGFloat
    var fontSize: CGFloat
    var separatorMargin: CGFloat

    /// The flavor's style with the theme's corner radius, text size, density and contrast.
    static func resolve(_ flavor: LunaMenuFlavor, dark: Bool) -> LunaMenuStyle {
        var s = base(flavor, dark: dark)
        let theme = ThemeStore.shared.theme
        s.cornerRadius = theme.radius(s.cornerRadius)
        s.hoverRadius = theme.radius(s.hoverRadius)
        s.fontSize = theme.font(s.fontSize)
        if theme.compact { s.rowHeight -= 4; s.verticalPadding = max(4, s.verticalPadding - 4) }
        if theme.highContrast { s.secondary = s.text; s.border = dark ? .white.opacity(0.24) : .black.opacity(0.24) }
        return s
    }

    private static func base(_ flavor: LunaMenuFlavor, dark: Bool) -> LunaMenuStyle {
        switch flavor {
        case .chrome:
            // Sampled from Chrome's ⋮ menu: light #FFFFFF / hover #F2F2F2 / separator #D6E2FB,
            // dark #1F1F1F / hover #363635 / separator #5E5E5E; text #1F1F1F / #E3E3E3.
            return LunaMenuStyle(
                background: dark ? Color(lunaHex: 0x1F1F1F) : .white,
                border: dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10),
                hover: dark ? Color(lunaHex: 0x363635) : Color(lunaHex: 0xF2F2F2),
                text: dark ? Color(lunaHex: 0xE3E3E3) : Color(lunaHex: 0x1F1F1F),
                secondary: dark ? Color(lunaHex: 0xC7C7C7) : Color(lunaHex: 0x474747),
                separator: dark ? Color(lunaHex: 0x5E5E5E) : Color(lunaHex: 0xD6E2FB),
                zoomButton: dark ? Color(lunaHex: 0x282828) : Color(lunaHex: 0xF2F2F2),
                shadow: .black.opacity(dark ? 0.55 : 0.20), shadowRadius: 10, shadowY: 4,
                verticalPadding: 12, horizontalPadding: 24, hoverInset: 0, hoverRadius: 0,
                fontSize: 13.5, separatorMargin: 8)
        case .luna:
            return LunaMenuStyle(
                background: dark ? Color(lunaHex: 0x1E1E20) : .white,
                border: dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10),
                hover: dark ? Color.white.opacity(0.09) : Color.black.opacity(0.055),
                text: dark ? Color(lunaHex: 0xEDEDED) : Color(lunaHex: 0x1D1D1F),
                secondary: dark ? Color.white.opacity(0.55) : Color.black.opacity(0.55),
                separator: dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08),
                zoomButton: dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                shadow: .black.opacity(dark ? 0.5 : 0.16), shadowRadius: 12, shadowY: 5,
                verticalPadding: 6, horizontalPadding: 14, hoverInset: 6, hoverRadius: 6,
                fontSize: 13, separatorMargin: 5)
        }
    }
}

/// The menu card: solid fill (or glass), hairline border, crisp shadow.
struct LunaMenuChrome: ViewModifier {
    let style: LunaMenuStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        content
            .background(shape.fill(style.background))
            .clipShape(shape)
            .overlay(shape.strokeBorder(style.border, lineWidth: 1))
            .compositingGroup()
            .shadow(color: style.shadow, radius: style.shadowRadius, y: style.shadowY)
            .shadow(color: .black.opacity(0.06), radius: 1, y: 0)
    }
}

// MARK: - Controller

enum LunaMenuPlacement {
    /// Under the anchor, aligned to its leading or trailing edge (flips above when it does not fit).
    case below(HorizontalAlignment)
    /// Above the anchor (flips below when it does not fit).
    case above(HorizontalAlignment)
    /// Top-left corner at a screen point (context menus).
    case point(CGPoint)
}

/// Owns the open menu: its panels (root + one per open submenu), the event
/// monitors that close it, and keyboard navigation.
@MainActor
final class LunaMenuController: ObservableObject {
    private(set) static weak var current: LunaMenuController?

    @Published private(set) var nav: LunaMenuNavigator
    let style: LunaMenuStyle
    let minWidth: CGFloat
    private let build: () -> [LunaMenuEntry]
    private let anchorRect: NSRect
    private let placement: LunaMenuPlacement
    private weak var parentWindow: NSWindow?
    private var panels: [LunaMenuPanel] = []
    var rowFrames: [Int: [String: CGRect]] = [:]
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var dwell: DispatchWorkItem?
    private var typed = ""
    private var typedAt = Date.distantPast
    private var onClose: (() -> Void)?
    private var isClosed = false

    static let margin: CGFloat = 22

    private init(build: @escaping () -> [LunaMenuEntry], anchorRect: NSRect, placement: LunaMenuPlacement,
                 window: NSWindow?, style: LunaMenuStyle, minWidth: CGFloat, onClose: (() -> Void)?) {
        self.build = build
        self.nav = LunaMenuNavigator(entries: build())
        self.anchorRect = anchorRect
        self.placement = placement
        self.parentWindow = window
        self.style = style
        self.minWidth = minWidth
        self.onClose = onClose
    }

    /// Opens a menu. `anchorRect` is in screen coordinates.
    @discardableResult
    static func present(anchorRect: NSRect, placement: LunaMenuPlacement, window: NSWindow?,
                        flavor: LunaMenuFlavor, minWidth: CGFloat = 0, highlightFirst: Bool = false,
                        build: @escaping () -> [LunaMenuEntry], onClose: (() -> Void)? = nil) -> LunaMenuController {
        current?.close()
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let style = LunaMenuStyle.resolve(flavor, dark: dark)
        let controller = LunaMenuController(build: build, anchorRect: anchorRect, placement: placement,
                                            window: window, style: style, minWidth: minWidth, onClose: onClose)
        if highlightFirst { controller.nav.move(1) }
        current = controller
        controller.open(appearance: appearance)
        return controller
    }

    private func open(appearance: NSAppearance) {
        sync(appearance: appearance)
        installMonitors()
        NSAccessibility.post(element: panels.first as Any, notification: .created)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        dwell?.cancel()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        panels.forEach { $0.parent?.removeChildWindow($0); $0.orderOut(nil) }
        panels.removeAll()
        if Self.current === self { Self.current = nil }
        let done = onClose
        onClose = nil
        done?()
    }

    // MARK: Actions from rows

    func hover(level: Int, entry: LunaMenuEntry) {
        nav.hover(level: level, id: entry.id)
        dwell?.cancel()
        if case .item(let item) = entry, item.isSubmenu, item.isEnabled {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.nav.highlightedID(level: level) == item.id else { return }
                self.nav.openSubmenu(level: level, highlightFirst: false)
                self.sync()
            }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
        sync()
    }

    func click(level: Int, item: LunaMenuItem) {
        guard item.isEnabled else { return }
        if item.isSubmenu {
            nav.hover(level: level, id: item.id)
            nav.openSubmenu(level: level, highlightFirst: false)
            sync()
        } else {
            perform(item)
        }
    }

    /// Runs a row's action: closes first (so modal work like Print runs outside the menu),
    /// unless the row keeps the menu open, in which case the menu rebuilds in place.
    func perform(_ item: LunaMenuItem) {
        if item.keepsOpen {
            item.action?()
            refresh()
        } else {
            close()
            if let action = item.action { DispatchQueue.main.async(execute: action) }
        }
    }

    /// Runs an inline control's action (zoom buttons) and rebuilds.
    func performInline(_ action: () -> Void) {
        action()
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh() {
        guard !isClosed else { return }
        nav.reload(build())
        sync()
    }

    // MARK: Panels

    private func sync(appearance: NSAppearance? = nil) {
        guard !isClosed else { return }
        while panels.count > nav.depth {
            let panel = panels.removeLast()
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        for level in 0..<nav.depth {
            let panel: LunaMenuPanel
            if level < panels.count {
                panel = panels[level]
            } else {
                panel = LunaMenuPanel(controller: self, level: level)
                panel.appearance = appearance ?? panels.first?.appearance
                panels.append(panel)
            }
            let size = panel.fittingSize()
            panel.setFrame(frame(for: level, size: size), display: true)
            if !panel.isVisible {
                // A child of the browser window: same Space, stays above it.
                if let parentWindow { parentWindow.addChildWindow(panel, ordered: .above) } else { panel.orderFront(nil) }
            }
        }
    }

    private func frame(for level: Int, size: NSSize) -> NSRect {
        let m = Self.margin
        let screen = (parentWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var menu = NSRect(origin: .zero, size: NSSize(width: size.width - 2 * m, height: size.height - 2 * m))
        if level == 0 {
            switch placement {
            case .below(let alignment), .above(let alignment):
                menu.origin.x = alignment == .trailing ? anchorRect.maxX - menu.width : anchorRect.minX
                let below = anchorRect.minY - 2 - menu.height
                let above = anchorRect.maxY + 2
                // Prefer staying inside the browser window (bottom bars open upward), then the screen.
                let floor = max(screen.minY, (parentWindow?.frame.minY ?? screen.minY))
                if case .below = placement {
                    menu.origin.y = below >= floor || above + menu.height > screen.maxY ? below : above
                } else {
                    menu.origin.y = above + menu.height <= screen.maxY || below < screen.minY ? above : below
                }
            case .point(let p):
                menu.origin = NSPoint(x: p.x, y: p.y - menu.height)
                if menu.minY < screen.minY { menu.origin.y = p.y }
            }
        } else {
            let parent = panels[level - 1].frame.insetBy(dx: m, dy: m)
            let parentID = nav.levels[level].parentID ?? ""
            let row = rowFrames[level - 1]?[parentID] ?? .zero
            let rowTop = panels[level - 1].frame.maxY - row.minY
            menu.origin.y = rowTop + style.verticalPadding - menu.height
            menu.origin.x = parent.maxX - 2
            if menu.maxX > screen.maxX { menu.origin.x = parent.minX - menu.width + 2 }
        }
        menu.origin.x = min(max(menu.minX, screen.minX + 4), screen.maxX - menu.width - 4)
        menu.origin.y = min(max(menu.minY, screen.minY + 4), screen.maxY - menu.height - 4)
        return menu.insetBy(dx: -m, dy: -m)
    }

    private func isOwnPanel(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return panels.contains { $0 === window }
    }

    // MARK: Events

    #if DEBUG
    /// Debug UI driver: keep menus open while the app is in the background (screenshots).
    static var debugPinned = false
    private var pinned: Bool { Self.debugPinned }
    #else
    private var pinned: Bool { false }
    #endif

    /// Closes because of something outside the menu (click, deactivation, window change).
    private func dismissFromOutside() {
        if !pinned { close() }
    }

    private func installMonitors() {
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            guard let self, !self.isClosed else { return event }
            if self.isOwnPanel(event.window) { return event }
            // A click outside closes the menu and is consumed (as with NSMenu), so the
            // button that opened it does not immediately reopen it.
            if self.pinned { return event }
            self.close()
            return nil
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in
            Task { @MainActor in self?.dismissFromOutside() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, !self.isClosed else { return event }
            let flags = event.modifierFlags.intersection([.command, .control])
            if !flags.isEmpty { self.close(); return event }
            return self.handleKey(event.keyCode, characters: event.charactersIgnoringModifiers) ? nil : event
        }) { monitors.append(m) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dismissFromOutside() }
        })
        if let window = parentWindow {
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.willCloseNotification,
                         NSWindow.didResignKeyNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.dismissFromOutside() }
                })
            }
        }
    }

    /// Returns true when the key was handled (and should not reach the window).
    private func handleKey(_ keyCode: UInt16, characters: String?) -> Bool {
        switch keyCode {
        case 125: nav.move(1)
        case 126: nav.move(-1)
        case 124:
            if nav.openSubmenu() {} else { return true }
        case 123:
            nav.closeSubmenu()
        case 36, 76, 49:
            switch nav.activate() {
            case .perform(let item): perform(item); return true
            case .openedSubmenu, .none: break
            }
        case 53:
            close()
            return true
        default:
            guard let chars = characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return true }
            typed = Date().timeIntervalSince(typedAt) < 0.8 ? typed + chars : chars
            typedAt = Date()
            nav.typeAhead(typed)
        }
        sync()
        return true
    }

    #if DEBUG
    /// Debug UI driver: highlight a row by title (and open it if it is a submenu).
    func debugHover(title: String) {
        for level in stride(from: nav.depth - 1, through: 0, by: -1) {
            if let entry = nav.levels[level].entries.first(where: { $0.selectableItem?.title == title }) {
                nav.hover(level: level, id: entry.id)
                if entry.selectableItem?.isSubmenu == true { nav.openSubmenu(level: level, highlightFirst: false) }
                sync()
                return
            }
        }
    }

    /// Debug UI driver: the same keys a user would press.
    func debugKey(_ name: String) {
        let codes: [String: UInt16] = ["down": 125, "up": 126, "right": 124, "left": 123, "return": 36, "esc": 53]
        if let code = codes[name] { _ = handleKey(code, characters: nil) } else { _ = handleKey(0xFFFF, characters: name) }
    }
    #endif
}

// MARK: - Panel

private final class LunaMenuHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class LunaMenuPanel: NSPanel {
    private let host: NSView

    @MainActor
    init(controller: LunaMenuController, level: Int) {
        let root = LunaMenuLevelView(controller: controller, level: level)
        host = LunaMenuHostingView(rootView: root)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = host
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Menu")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func fittingSize() -> NSSize {
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}

// MARK: - Views

private struct LunaMenuRowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct LunaMenuLevelView: View {
    @ObservedObject var controller: LunaMenuController
    let level: Int

    private var style: LunaMenuStyle { controller.style }

    var body: some View {
        let levels = controller.nav.levels
        VStack(alignment: .leading, spacing: 0) {
            if levels.indices.contains(level) {
                ForEach(levels[level].entries) { entry in
                    row(entry, highlighted: controller.nav.highlightedID(level: level) == entry.id)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: LunaMenuRowFramesKey.self,
                                                   value: [entry.id: g.frame(in: .named("lunaMenuPanel"))])
                        })
                }
            }
        }
        .padding(.vertical, style.verticalPadding)
        .frame(minWidth: level == 0 ? controller.minWidth : 200, alignment: .leading)
        .fixedSize()
        .modifier(LunaMenuChrome(style: style))
        .padding(LunaMenuController.margin)
        .coordinateSpace(name: "lunaMenuPanel")
        .onPreferenceChange(LunaMenuRowFramesKey.self) { frames in
            MainActor.assumeIsolated { controller.rowFrames[level] = frames }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu")
    }

    @ViewBuilder
    private func row(_ entry: LunaMenuEntry, highlighted: Bool) -> some View {
        switch entry {
        case .separator:
            Rectangle().fill(style.separator).frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, style.separatorMargin)
                .accessibilityHidden(true)
        case .header(let title):
            Text(title)
                .font(.system(size: style.fontSize + 0.5, weight: .semibold))
                .foregroundStyle(style.text)
                .padding(.horizontal, style.horizontalPadding)
                .frame(maxWidth: .infinity, minHeight: style.rowHeight + 4, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .zoom(let zoom):
            LunaMenuZoomRow(zoom: zoom, style: style, perform: { controller.performInline($0) })
                .onHover { if $0 { controller.hover(level: level, entry: entry) } }
        case .item(let item):
            LunaMenuRow(item: item, style: style, highlighted: highlighted,
                        submenuOpen: controller.nav.depth > level + 1
                            && controller.nav.levels[level + 1].parentID == item.id,
                        hasIconColumn: hasIconColumn)
                .contentShape(Rectangle())
                .onHover { if $0 { controller.hover(level: level, entry: entry) } }
                .onTapGesture { controller.click(level: level, item: item) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.shortcut ?? "")
                .accessibilityAddTraits(item.isChecked ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(item.isSubmenu ? "Submenu" : "")
                .accessibilityAction { controller.click(level: level, item: item) }
        }
    }

    /// Reserve the icon column when any row in this menu has an icon or a checkmark.
    private var hasIconColumn: Bool {
        guard controller.nav.levels.indices.contains(level) else { return false }
        return controller.nav.levels[level].entries.contains {
            if case .item(let item) = $0 { return item.icon != nil || item.isChecked }
            if case .zoom = $0 { return true }
            return false
        }
    }
}

private struct LunaMenuRow: View {
    let item: LunaMenuItem
    let style: LunaMenuStyle
    let highlighted: Bool
    let submenuOpen: Bool
    let hasIconColumn: Bool

    var body: some View {
        HStack(spacing: 0) {
            if hasIconColumn {
                icon.frame(width: 20, height: 20).padding(.trailing, 12)
            }
            Text(item.title)
                .font(.system(size: style.fontSize))
                .foregroundStyle(item.isDestructive ? Color.red : style.text)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 32)
            if item.isChecked, item.icon != nil {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(style.text)
            } else if item.isSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(style.secondary)
            } else if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: style.fontSize - 0.5))
                    .foregroundStyle(style.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, style.horizontalPadding - style.hoverInset)
        .frame(maxWidth: .infinity, minHeight: style.rowHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: style.hoverRadius, style: .continuous)
                .fill((highlighted || submenuOpen) && item.isEnabled ? style.hover : .clear)
        )
        .padding(.horizontal, style.hoverInset)
        .opacity(item.isEnabled ? 1 : 0.38)
    }

    @ViewBuilder
    private var icon: some View {
        if item.isChecked, item.icon == nil {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.text)
        } else {
            switch item.icon {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(style.secondary)
            case .image(let image):
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 16, height: 16)
            case nil:
                Color.clear
            }
        }
    }
}

private struct LunaMenuZoomRow: View {
    let zoom: LunaMenuZoom
    let style: LunaMenuStyle
    let perform: (() -> Void) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(style.secondary)
                .frame(width: 20, height: 20)
                .padding(.trailing, 12)
            Text("Zoom")
                .font(.system(size: style.fontSize))
                .foregroundStyle(style.text)
            Spacer(minLength: 24)
            circle("minus", label: "Make text smaller") { perform(zoom.zoomOut) }
            Text(zoom.level)
                .font(.system(size: style.fontSize).monospacedDigit())
                .foregroundStyle(style.text)
                .frame(width: 58)
                .accessibilityLabel("Zoom level \(zoom.level)")
            circle("plus", label: "Make text larger") { perform(zoom.zoomIn) }
            if let fullScreen = zoom.fullScreen {
                Rectangle().fill(style.separator).frame(width: 1, height: 28).padding(.horizontal, 10)
                circle("viewfinder", label: "Full screen") { perform(fullScreen) }
            }
        }
        .padding(.leading, style.horizontalPadding)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: style.rowHeight + 1)
    }

    private func circle(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        ZoomCircle(systemName: systemName, style: style, action: action)
            .accessibilityLabel(label)
    }

    private struct ZoomCircle: View {
        let systemName: String
        let style: LunaMenuStyle
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.text)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(hovering ? style.hover : style.zoomButton))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

// MARK: - SwiftUI entry points

/// Captures the NSView a SwiftUI view is drawn in, to anchor menus to it.
final class LunaAnchorBox {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

struct LunaAnchorView: NSViewRepresentable {
    let box: LunaAnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        box.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct LunaMenuPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let placement: (NSRect) -> LunaMenuPlacement
    let minWidth: CGFloat
    let build: () -> [LunaMenuEntry]
    @Environment(\.lunaMenuFlavor) private var flavor
    @State private var box = LunaAnchorBox()
    @State private var controller: LunaMenuController?

    func body(content: Content) -> some View {
        content
            .background(LunaAnchorView(box: box))
            .onChange(of: isPresented) { _, open in
                if open { show() } else { controller?.close(); controller = nil }
            }
            .onAppear { if isPresented { show() } }
            .onDisappear { controller?.close() }
    }

    private func show() {
        guard let rect = box.screenRect else { isPresented = false; return }
        controller = LunaMenuController.present(
            anchorRect: rect, placement: placement(rect), window: box.view?.window, flavor: flavor,
            minWidth: minWidth, build: build, onClose: { isPresented = false })
    }
}

extension View {
    /// Shows a Luna menu anchored to this view while `isPresented` is true.
    func lunaMenu(isPresented: Binding<Bool>, alignment: HorizontalAlignment = .leading, minWidth: CGFloat = 0,
                  _ build: @escaping () -> [LunaMenuEntry]) -> some View {
        modifier(LunaMenuPresenter(isPresented: isPresented, placement: { _ in .below(alignment) },
                                   minWidth: minWidth, build: build))
    }

    /// Shows a Luna menu above this view while `isPresented` is true.
    func lunaMenuAbove(isPresented: Binding<Bool>, alignment: HorizontalAlignment = .leading, minWidth: CGFloat = 0,
                       _ build: @escaping () -> [LunaMenuEntry]) -> some View {
        modifier(LunaMenuPresenter(isPresented: isPresented, placement: { _ in .above(alignment) },
                                   minWidth: minWidth, build: build))
    }

    /// Right-click (or control-click) shows a Luna menu at the pointer.
    func lunaContextMenu(_ build: @escaping () -> [LunaMenuEntry]) -> some View {
        modifier(LunaContextMenuModifier(build: build))
    }
}

/// A button that opens a Luna menu. The label gets whether the menu is open.
struct LunaMenuButton<Label: View>: View {
    var alignment: HorizontalAlignment = .leading
    var minWidth: CGFloat = 0
    var help: String?
    /// Open above the button (bottom bars).
    var opensAbove = false
    /// Names the menu for the debug UI driver (`menu:<id>`).
    var debugID: String?
    let items: () -> [LunaMenuEntry]
    @ViewBuilder let label: (_ isOpen: Bool) -> Label
    @State private var isOpen = false

    init(alignment: HorizontalAlignment = .leading, minWidth: CGFloat = 0, help: String? = nil, opensAbove: Bool = false,
         debugID: String? = nil,
         items: @escaping () -> [LunaMenuEntry], @ViewBuilder label: @escaping (_ isOpen: Bool) -> Label) {
        self.opensAbove = opensAbove
        self.alignment = alignment
        self.minWidth = minWidth
        self.help = help
        self.debugID = debugID
        self.items = items
        self.label = label
    }

    var body: some View {
        Button { isOpen.toggle() } label: { label(isOpen) }
            .buttonStyle(.plain)
            .modifier(LunaMenuPresenter(isPresented: $isOpen,
                                        placement: { _ in opensAbove ? .above(alignment) : .below(alignment) },
                                        minWidth: minWidth, build: items))
            .help(help ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens a menu")
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .lunaDebugOpenMenu)) { note in
                if let debugID, note.object as? String == debugID { isOpen = true }
            }
            #endif
    }
}

// MARK: - Context menus

private struct LunaContextMenuModifier: ViewModifier {
    let build: () -> [LunaMenuEntry]
    @Environment(\.lunaMenuFlavor) private var flavor

    func body(content: Content) -> some View {
        content.overlay(LunaRightClickCatcher(flavor: flavor, build: build))
    }
}

/// Catches right-clicks (and control-clicks) over a SwiftUI view; every other
/// event passes through to the view underneath.
private struct LunaRightClickCatcher: NSViewRepresentable {
    let flavor: LunaMenuFlavor
    let build: () -> [LunaMenuEntry]

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) {
        view.flavor = flavor
        view.build = build
    }

    final class CatcherView: NSView {
        var flavor: LunaMenuFlavor = .luna
        var build: (() -> [LunaMenuEntry])?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isContext = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isContext ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { show(event) }
        override func mouseDown(with event: NSEvent) { show(event) }
        override func menu(for event: NSEvent) -> NSMenu? { nil }

        private func show(_ event: NSEvent) {
            guard let window, let build else { return }
            let entries = build()
            guard !entries.isEmpty else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            LunaMenuController.present(anchorRect: NSRect(origin: point, size: .zero), placement: .point(point),
                                       window: window, flavor: flavor, build: build)
        }
    }
}

/// Shows a Luna menu for an AppKit view at a mouse event (outline views, etc.).
@MainActor
func presentLunaContextMenu(_ entries: @escaping () -> [LunaMenuEntry], for event: NSEvent, in view: NSView,
                            flavor: LunaMenuFlavor = .luna) {
    guard let window = view.window else { return }
    let point = window.convertPoint(toScreen: event.locationInWindow)
    LunaMenuController.present(anchorRect: NSRect(origin: point, size: .zero), placement: .point(point),
                               window: window, flavor: flavor, build: entries)
}
