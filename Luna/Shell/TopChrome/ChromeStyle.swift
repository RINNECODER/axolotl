import AppKit
import SwiftUI

// The "Chrome" layout template: Google Chrome's window chrome, measured from Chrome 155 on macOS
// (light and dark, 1280×800 window, 2x captures).

/// Chrome's default-theme colors.
struct ChromePalette {
    let frame: Color          // tab strip / title bar
    let toolbar: Color        // active tab, toolbar, bookmarks bar
    let omnibox: Color
    let tabSeparator: Color
    let tabHover: Color
    let tabSearch: Color
    let contentSeparator: Color  // line between the bookmarks bar and the page
    let bookmarkSeparator: Color
    let icon: Color
    let title: Color          // active tab title, URL text
    let inactiveTitle: Color
    let star: Color
    let hover: Color          // toolbar button hover circle

    static func `for`(_ scheme: ColorScheme) -> ChromePalette { scheme == .dark ? dark : light }

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
                .font(.system(size: 12.25))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isActive ? palette.title : palette.inactiveTitle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82),
                                             .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
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
        Menu {
            ForEach(store.orderedTabIds, id: \.self) { id in
                if let tab = store.tab(id) {
                    Button(displayTitle(for: tab)) { onActivate(id) }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.title)
                .frame(width: ChromeMetrics.tabSearchSize, height: ChromeMetrics.tabSearchSize)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.tabSearch))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Search Tabs")
    }
}

// MARK: - Traffic lights

/// Moves the window buttons to Chrome's spot (centered in the 40 pt tab strip) while enabled,
/// and puts them back when disabled or removed.
struct TrafficLightPositioner: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> PositionerView { PositionerView() }

    func updateNSView(_ view: PositionerView, context: Context) {
        view.enabled = enabled
    }

    static func dismantleNSView(_ view: PositionerView, coordinator: ()) {
        view.tearDown()
    }

    final class PositionerView: NSView {
        var enabled = false { didSet { if enabled != oldValue { schedule() } } }
        private var original: (container: NSRect, buttons: [NSRect])?
        private var observers: [NSObjectProtocol] = []
        /// The last window we moved buttons in, so they can be restored after the view has left it.
        private weak var attachedWindow: NSWindow?

        /// Restores the buttons right now and stops observing; used when the view is removed.
        func tearDown() {
            enabled = false
            removeObservers()
            apply()
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
                return
            }
            attachedWindow = window
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                })
            }
            schedule()
        }

        nonisolated deinit {}

        private func schedule() { DispatchQueue.main.async { [weak self] in self?.apply() } }

        private func apply() {
            guard let window = window ?? attachedWindow, !window.styleMask.contains(.fullScreen) else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            guard buttons.count == 3, let container = buttons[0].superview?.superview else { return }
            if !enabled {
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
