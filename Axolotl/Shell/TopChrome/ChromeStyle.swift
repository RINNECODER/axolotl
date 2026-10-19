import AppKit
import SwiftUI

// The "Chrome" layout template: Google Chrome's window chrome, measured from Chrome 155 on macOS
// (light and dark, 1280×800 window, 2x captures).

/// Chrome's default-theme colors.
struct ChromePalette {
    var frame: Color          // tab strip / title bar
    var toolbar: Color        // active tab, toolbar, bookmarks bar
    let omnibox: Color
    let tabSeparator: Color
    let tabHover: Color
    let tabSearch: Color
    let contentSeparator: Color  // line between the bookmarks bar and the page
    let bookmarkSeparator: Color
    let icon: Color
    let title: Color          // active tab title, URL text
    var inactiveTitle: Color
    var star: Color
    let hover: Color          // toolbar button hover circle

    /// Chrome's palette with the theme's tab strip, active tab and accent colors (the Chrome theme preset is Chrome's own).
    static func `for`(_ scheme: ColorScheme) -> ChromePalette {
        let isDark = scheme == .dark
        var p = isDark ? dark : light
        let theme = ThemeStore.shared.theme
        p.frame = Color(chromeHex: theme.pair(.toolbar).hex(dark: isDark))
        p.toolbar = Color(chromeHex: theme.pair(.activeTab).hex(dark: isDark))
        p.star = Color(chromeHex: theme.pair(.accent).hex(dark: isDark))
        if theme.highContrast { p.inactiveTitle = p.title }
        return p
    }

    static let light = ChromePalette(
        frame: Color(chromeHex: 0xD6E2FB), toolbar: .white, omnibox: Color(chromeHex: 0xEEF2F9),
        tabSeparator: Color(chromeHex: 0xAEC6F6), tabHover: Color(chromeHex: 0xE6EDFC), tabSearch: Color(chromeHex: 0xEDF3FD),
        contentSeparator: Color(chromeHex: 0xE1E3E1), bookmarkSeparator: Color(chromeHex: 0xD6E2FB),
        icon: Color(chromeHex: 0x474747), title: Color(chromeHex: 0x1F1F1F), inactiveTitle: Color(chromeHex: 0x474747),
        star: Color(chromeHex: 0x3265CB), hover: Color.black.opacity(0.06))

    static let dark = ChromePalette(
        frame: Color(chromeHex: 0x1F2020), toolbar: Color(chromeHex: 0x3C3C3C), omnibox: Color(chromeHex: 0x282828),
        tabSeparator: Color(chromeHex: 0x5E5E5E), tabHover: Color(chromeHex: 0x2C2D2D), tabSearch: Color(chromeHex: 0x3C3C3C),
        contentSeparator: Color(chromeHex: 0x454746), bookmarkSeparator: Color(chromeHex: 0x5E5E5E),
        icon: Color(chromeHex: 0xC7C7C7), title: Color(chromeHex: 0xE3E3E3), inactiveTitle: Color(chromeHex: 0xC7C7C7),
        star: Color(chromeHex: 0x729CEF), hover: Color.white.opacity(0.08))
}

extension Color {
    init(chromeHex hex: UInt32) {
        // Device RGB, like Chrome's own drawing, so the values land on screen unchanged.
        self.init(nsColor: NSColor(deviceRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                                   blue: CGFloat(hex & 0xFF) / 255, alpha: 1))
    }
}

/// Chrome's geometry, in points.
enum ChromeMetrics {
    static let tabStripHeight: CGFloat = 40
    /// Gap above the tabs; a tab runs from here to the toolbar.
    static let tabTop: CGFloat = 6
    static let toolbarHeight: CGFloat = 46
    static let omniboxHeight: CGFloat = 34
    static let toolbarButton: CGFloat = 34
    static let bookmarksBarHeight: CGFloat = 34
    static var height: CGFloat { tabStripHeight + toolbarHeight }

    /// Traffic lights: first button's leading edge, and their vertical center from the window top.
    static let trafficLightLeading: CGFloat = 13.5
    static let trafficLightCenterY: CGFloat = 21
    /// Tab search button (28×28) after the traffic lights.
    static let tabSearchLeading: CGFloat = 92
    static let tabSearchSize: CGFloat = 28
    /// Distance from the window edge to the first tab slot.
    static let tabsLeading: CGFloat = 123

    /// Tab pitch (slot width) bounds: Chrome's tabs stop growing at 238 pt and shrink evenly to fit.
    static let maxTabPitch: CGFloat = 238
    static let minTabPitch: CGFloat = 40
    static let pinnedTabPitch: CGFloat = 48
    /// The tab body sits this far inside its slot; the bottom flares reach past it.
    static let tabInset: CGFloat = 3
    static let tabRadius: CGFloat = 10
    static let tabFlare: CGFloat = 10
    /// Space the "+" button takes after the last tab.
    static let newTabButtonWidth: CGFloat = 32

    /// Width of each titled tab's slot: the strip's free width shared evenly, clamped to Chrome's bounds.
    /// Below the minimum the strip scrolls.
    static func tabPitch(available: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return min(maxTabPitch, max(minTabPitch, (available / CGFloat(count)).rounded(.down)))
    }

    /// Chrome hides inactive tabs' close buttons once tabs get this narrow.
    static func showsClose(pitch: CGFloat, isActive: Bool) -> Bool { isActive || pitch >= 76 }

    /// Too narrow for a title: inactive tabs show just the favicon, the active tab just its close button.
    static func isNarrow(pitch: CGFloat) -> Bool { pitch < 60 }
}

/// Chrome's tab: rounded top corners, straight sides, and bottom corners that flare out into the toolbar.
struct ChromeTabShape: Shape {
    var inset: CGFloat = ChromeMetrics.tabInset
    var radius: CGFloat = ChromeMetrics.tabRadius
    var flare: CGFloat = ChromeMetrics.tabFlare

    func path(in rect: CGRect) -> Path {
        let l = rect.minX + inset, r = rect.maxX - inset, t = rect.minY, b = rect.maxY
        // Round top corners (circular), and bottom flares that bend out early and sweep wide
        // (fitted to Chrome's outline: 2.5 pt out at 5 pt above the toolbar, ~9.5 pt at the bottom).
        let k = radius * (1 - 0.5523)
        let w = flare * 0.95
        var p = Path()
        p.move(to: CGPoint(x: l - w, y: b))
        p.addCurve(to: CGPoint(x: l, y: b - flare), control1: CGPoint(x: l - w * 0.42, y: b), control2: CGPoint(x: l - w * 0.16, y: b - flare * 0.5))
        p.addLine(to: CGPoint(x: l, y: t + radius))
        p.addCurve(to: CGPoint(x: l + radius, y: t), control1: CGPoint(x: l, y: t + k), control2: CGPoint(x: l + k, y: t))
        p.addLine(to: CGPoint(x: r - radius, y: t))
        p.addCurve(to: CGPoint(x: r, y: t + radius), control1: CGPoint(x: r - k, y: t), control2: CGPoint(x: r, y: t + k))
        p.addLine(to: CGPoint(x: r, y: b - flare))
        p.addCurve(to: CGPoint(x: r + w, y: b), control1: CGPoint(x: r + w * 0.16, y: b - flare * 0.5), control2: CGPoint(x: r + w * 0.42, y: b))
        p.closeSubpath()
        return p
    }
}

/// A tab drawn the Chrome way; sits in a slot `ChromeMetrics.tabPitch` wide and 34 pt tall.
struct ChromeTabView: View {
    let tab: Tab
    let faviconURL: URL?
    let isActive: Bool
    let isLoading: Bool
    let iconOnly: Bool
    let showsSeparator: Bool
    let showsClose: Bool
    let isHovered: Bool
    var narrow = false
    var audio = TabAudioState.silent
    let onClose: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var closeHovered = false

    var body: some View {
        let palette = ChromePalette.for(scheme)
        let inset = ChromeMetrics.tabInset
        HStack(spacing: 8) {
            if narrow {
                if isActive { closeButton(palette) } else { favicon }
            } else {
                full(palette)
            }
        }
        .padding(.leading, iconOnly || narrow ? 0 : inset + 8)
        .padding(.trailing, iconOnly || narrow ? 0 : inset + 5)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            if isActive || isHovered {
                ChromeTabShape()
                    .fill(isActive ? palette.toolbar : palette.tabHover)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsSeparator {
                Rectangle().fill(palette.tabSeparator)
                    .frame(width: 1, height: 16)
                    .offset(x: -0.5, y: 6)
            }
        }
        .padding(.top, ChromeMetrics.tabTop)
    }

    private var favicon: some View {
        ZStack {
            TabIcon(tab: tab, faviconURL: faviconURL)
                .opacity(isLoading ? 0.35 : 1)
            if isLoading { ProgressView().controlSize(.mini) }
        }
        .frame(width: 16, height: 16)
    }

    @ViewBuilder
    private func full(_ palette: ChromePalette) -> some View {
        favicon
        if !iconOnly {
            // Chrome fades a long title out instead of truncating it.
            Text(displayTitle(for: tab))
                .font(.system(size: ThemeStore.shared.theme.font(12.25)))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isActive ? palette.title : palette.inactiveTitle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82),
                                             .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
            TabAudioButton(audio: audio, color: isActive ? palette.title : palette.inactiveTitle)
            if showsClose { closeButton(palette) }
        }
    }

    private func closeButton(_ palette: ChromePalette) -> some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(isActive ? palette.title : palette.inactiveTitle)
                .frame(width: 20, height: 20)
                .background(Circle().fill(palette.hover.opacity(closeHovered ? 2 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { closeHovered = $0 }
        .help("Close Tab (⌘W)")
        .accessibilityLabel("Close Tab")
    }
}

/// Chrome's toolbar button: a 34 pt hover circle around a 16 pt icon.
struct ChromeToolbarButton: View {
    let systemName: String
    let help: String
    var isEnabled = true
    var tint: Color?
    var rotation: Angle = .zero
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        let palette = ChromePalette.for(scheme)
        Button(action: action) {
            ChromeIcon(systemName: systemName, color: tint ?? palette.icon, rotation: rotation)
                .opacity(isEnabled ? 1 : 0.38)
                .frame(width: ChromeMetrics.toolbarButton, height: ChromeMetrics.toolbarButton)
                .background(Circle().fill(palette.hover.opacity(isHovering && isEnabled ? 1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct ChromeIcon: View {
    let systemName: String
    let color: Color
    var rotation: Angle = .zero
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
            .rotationEffect(rotation)
            .frame(width: 20, height: 20)
    }
}

/// Tab search (the chevron in a rounded square after the window buttons): lists the open tabs.
struct ChromeTabSearchButton: View {
    @ObservedObject var store: WorkspaceStore
    let onActivate: (UUID) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ChromePalette.for(scheme)
        AxolotlMenuButton(minWidth: 280, debugID: "chrome.tabs", items: {
            var entries: [AxolotlMenuEntry] = [.header("Open tabs")]
            for id in store.orderedTabIds {
                guard let tab = store.tab(id) else { continue }
                entries.append(.item(AxolotlMenuItem(id: "tab.\(id)", title: displayTitle(for: tab),
                                                  icon: AxolotlMenuEntry.favicon(tab.url).map { .image($0) },
                                                  isChecked: false, action: { onActivate(id) })))
            }
            return entries
        }) { isOpen in
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.title)
                .frame(width: ChromeMetrics.tabSearchSize, height: ChromeMetrics.tabSearchSize)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOpen ? palette.tabHover : palette.tabSearch))
                .contentShape(Rectangle())
        }
        .fixedSize()
        .help("Search Tabs")
        .accessibilityLabel("Search Tabs")
    }
}

// MARK: - Traffic lights

/// Moves the window buttons to Chrome's spot (centered in the 40 pt tab strip) while enabled,
/// and puts them back when disabled or removed.
///
/// In full screen AppKit moves the real buttons into the (hidden) full-screen titlebar, so this
/// draws Axolotl's own buttons in the frames the real ones had in the window, so nothing shifts.
struct TrafficLightPositioner: NSViewRepresentable {
    let enabled: Bool
    /// The layout hides the window buttons (frameless, hidden sidebar); full screen follows it.
    var hiddenInFullScreen = false

    func makeNSView(context: Context) -> PositionerView { PositionerView() }

    func updateNSView(_ view: PositionerView, context: Context) {
        view.enabled = enabled
        view.hiddenInFullScreen = hiddenInFullScreen
    }

    static func dismantleNSView(_ view: PositionerView, coordinator: ()) {
        view.tearDown()
    }

    final class PositionerView: NSView {
        var enabled = false { didSet { if enabled != oldValue { schedule() } } }
        var hiddenInFullScreen = false { didSet { if hiddenInFullScreen != oldValue { updateFullScreenButtons() } } }
        private var original: (container: NSRect, buttons: [NSRect])?
        private var observers: [NSObjectProtocol] = []
        /// The last window we moved buttons in, so they can be restored after the view has left it.
        private weak var attachedWindow: NSWindow?
        /// Button frames in the window while windowed, as (x, distance from the window top, w, h).
        private var windowedFrames: [NSRect]?
        private var inFullScreen = false
        private var fullScreenButtons: FullScreenWindowButtons?

        /// Restores the buttons right now and stops observing; used when the view is removed.
        func tearDown() {
            enabled = false
            removeObservers()
            apply()
            fullScreenButtons?.removeFromSuperview()
            fullScreenButtons = nil
            attachedWindow = nil
        }

        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else {
                // Left the window: put the buttons back synchronously, nothing is scheduled.
                enabled = false
                apply()
                fullScreenButtons?.removeFromSuperview()
                fullScreenButtons = nil
                return
            }
            attachedWindow = window
            inFullScreen = window.styleMask.contains(.fullScreen)
            // Entering full screen: note where the buttons sit, then put the system button container
            // back before the transition so macOS owns it.
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.captureWindowedFrames()
                    self.apply(restoring: true)
                    self.inFullScreen = true
                    self.updateFullScreenButtons()
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFullScreen = false
                    self.updateFullScreenButtons()
                    self.apply()
                }
            })
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                })
            }
            schedule()
        }

        nonisolated deinit {}

        private func schedule() { DispatchQueue.main.async { [weak self] in self?.apply() } }

        private func systemButtons(_ window: NSWindow) -> [NSButton] {
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        }

        /// Records the real buttons' frames, measured from the window's top-left, while they are in the window.
        private func captureWindowedFrames() {
            guard let window = window ?? attachedWindow else { return }
            let buttons = systemButtons(window)
            guard buttons.count == 3, buttons[0].window === window else { return }
            let height = window.frame.height
            windowedFrames = buttons.map { b in
                let r = b.convert(b.bounds, to: nil)
                return NSRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
            }
        }

        private func updateFullScreenButtons() {
            guard let window = window ?? attachedWindow, let host = window.contentView else { return }
            guard inFullScreen, !hiddenInFullScreen else {
                fullScreenButtons?.isHidden = true
                return
            }
            let frames = windowedFrames ?? fallbackFrames(window)
            guard let first = frames.first, let last = frames.last else { return }
            let view: FullScreenWindowButtons
            if let existing = fullScreenButtons, existing.superview === host {
                view = existing
            } else {
                fullScreenButtons?.removeFromSuperview()
                view = FullScreenWindowButtons()
                host.addSubview(view, positioned: .above, relativeTo: nil)
                fullScreenButtons = view
            }
            let top = frames.map(\.minY).min() ?? first.minY
            let bottom = frames.map(\.maxY).max() ?? first.maxY
            let size = NSSize(width: last.maxX - first.minX, height: bottom - top)
            let y = host.isFlipped ? top : host.bounds.height - bottom
            view.frame = NSRect(origin: NSPoint(x: first.minX, y: y), size: size)
            view.autoresizingMask = host.isFlipped ? [.maxXMargin, .maxYMargin] : [.maxXMargin, .minYMargin]
            view.circles = frames.map { NSRect(x: $0.minX - first.minX, y: $0.minY - top, width: $0.width, height: $0.height) }
            view.isHidden = false
            view.needsDisplay = true
        }

        /// Without a windowed measurement (launched in full screen): the system spot, or Chrome's.
        private func fallbackFrames(_ window: NSWindow) -> [NSRect] {
            let buttons = systemButtons(window)
            let size = buttons.first?.frame.size ?? NSSize(width: 14, height: 16)
            let pitch = buttons.count == 3 ? buttons[1].frame.minX - buttons[0].frame.minX : 20
            let leading = enabled ? ChromeMetrics.trafficLightLeading : (buttons.first?.frame.minX ?? 7.5)
            let centerY = enabled ? ChromeMetrics.trafficLightCenterY : 14
            return (0..<3).map { i in
                NSRect(x: leading + CGFloat(i) * pitch, y: centerY - size.height / 2, width: size.width, height: size.height)
            }
        }

        private func apply(restoring: Bool = false) {
            guard let window = window ?? attachedWindow else { return }
            fullScreenButtons?.needsDisplay = true
            // In full screen the system owns the buttons; never reposition or capture them mid-transition.
            if window.styleMask.contains(.fullScreen) && !restoring { return }
            defer { if !restoring && !inFullScreen { captureWindowedFrames() } }
            let buttons = systemButtons(window)
            guard buttons.count == 3, let container = buttons[0].superview?.superview else { return }
            if !enabled || restoring {
                guard let original else { return }
                container.frame = original.container
                for (b, f) in zip(buttons, original.buttons) { b.setFrameOrigin(f.origin) }
                self.original = nil
                return
            }
            if original == nil { original = (container.frame, buttons.map(\.frame)) }
            let height = ChromeMetrics.tabStripHeight
            let windowHeight = window.frame.height
            container.frame = NSRect(x: container.frame.minX, y: windowHeight - height, width: container.frame.width, height: height)
            let pitch = original.map { $0.buttons[1].minX - $0.buttons[0].minX } ?? 20
            for (i, b) in buttons.enumerated() {
                let y = height - ChromeMetrics.trafficLightCenterY - b.frame.height / 2
                b.setFrameOrigin(NSPoint(x: ChromeMetrics.trafficLightLeading + CGFloat(i) * pitch, y: y))
            }
        }
    }
}

/// Close / minimize / zoom drawn by Axolotl in full screen, where AppKit has moved the real buttons
/// into the hidden full-screen titlebar. Minimize is disabled, as macOS does in full screen;
/// zoom leaves full screen. Hover shows the glyphs; an inactive window shows them gray.
final class FullScreenWindowButtons: NSView {
    /// The three button frames (each holds a centered circle), in this view's coordinates.
    var circles: [NSRect] = [] { didSet { needsDisplay = true } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var pressed: Int?
    private var pressedInside = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    private func index(at point: NSPoint) -> Int? {
        circles.firstIndex { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        guard let i, i != 1 else { return }
        pressed = i
        pressedInside = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        let inside = index(at: convert(event.locationInWindow, from: nil)) == pressed
        if inside != pressedInside { pressedInside = inside; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = pressed else { return }
        let fire = index(at: convert(event.locationInWindow, from: nil)) == i
        pressed = nil
        pressedInside = false
        needsDisplay = true
        guard fire, let window else { return }
        if i == 0 { window.performClose(nil) } else if i == 2 { window.toggleFullScreen(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard circles.count == 3 else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let active = (window?.isKeyWindow ?? false) || hovering
        let gray = dark ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.13)
        let grayBorder = dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.07)
        let colors: [(NSColor, NSColor)] = [
            (NSColor(srgbRed: 1.0, green: 0.373, blue: 0.341, alpha: 1), NSColor(srgbRed: 0.878, green: 0.267, blue: 0.243, alpha: 1)),
            (gray, grayBorder),
            (NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1), NSColor(srgbRed: 0.102, green: 0.671, blue: 0.161, alpha: 1)),
        ]
        for (i, frame) in circles.enumerated() {
            // The system circle fills the button's width (12–14 pt depending on the macOS version).
            let d = min(14, max(12, min(frame.width, frame.height)))
            let rect = NSRect(x: frame.midX - d / 2, y: frame.midY - d / 2, width: d, height: d)
            let (fill, border) = (active || i == 1) ? colors[i] : (gray, grayBorder)
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            border.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25))
            ring.lineWidth = 0.5
            ring.stroke()
            if pressed == i && pressedInside {
                NSColor(white: 0, alpha: 0.18).setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
            guard hovering, i != 1 else { continue }
            NSColor(white: 0, alpha: 0.55).set()
            let c = NSPoint(x: rect.midX, y: rect.midY)
            if i == 0 {
                let a: CGFloat = 2.6
                let x = NSBezierPath()
                x.move(to: NSPoint(x: c.x - a, y: c.y - a)); x.line(to: NSPoint(x: c.x + a, y: c.y + a))
                x.move(to: NSPoint(x: c.x + a, y: c.y - a)); x.line(to: NSPoint(x: c.x - a, y: c.y + a))
                x.lineWidth = 1.1
                x.lineCapStyle = .round
                x.stroke()
            } else {
                // Exit full screen: two triangles pointing at the center.
                let g: CGFloat = 0.6, s: CGFloat = 3.6
                for sign in [CGFloat(-1), 1] {
                    let corner = NSPoint(x: c.x + sign * g, y: c.y + sign * g)
                    let t = NSBezierPath()
                    t.move(to: corner)
                    t.line(to: NSPoint(x: corner.x + sign * s, y: corner.y))
                    t.line(to: NSPoint(x: corner.x, y: corner.y + sign * s))
                    t.close()
                    t.fill()
                }
            }
        }
    }

    override func isAccessibilityElement() -> Bool { false }
}

/// Chrome's site-information ("tune") icon: two lines, each with a knob.
struct ChromeSiteInfoIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.height * 0.21
        var p = Path()
        let y1 = rect.minY + r + 0.75, y2 = rect.maxY - r - 0.75
        p.addEllipse(in: CGRect(x: rect.minX + 0.75, y: y1 - r, width: 2 * r, height: 2 * r))
        p.move(to: CGPoint(x: rect.minX + 0.75 + 2 * r + 2, y: y1)); p.addLine(to: CGPoint(x: rect.maxX, y: y1))
        p.move(to: CGPoint(x: rect.minX, y: y2)); p.addLine(to: CGPoint(x: rect.maxX - 0.75 - 2 * r - 2, y: y2))
        p.addEllipse(in: CGRect(x: rect.maxX - 0.75 - 2 * r, y: y2 - r, width: 2 * r, height: 2 * r))
        return p
    }
}
