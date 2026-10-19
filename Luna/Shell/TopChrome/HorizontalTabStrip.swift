import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Helium-style horizontal tabs: favorites and pinned tabs as icon-only tabs,
/// Today tabs with titles, thin separators, the active tab on a soft fill.
struct HorizontalTabStrip: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var web: WebViewWrapper
    var height: CGFloat = 30
    let onActivate: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNewTab: () -> Void
    /// Dropped tab, target tab: open them side by side.
    let onSplit: (UUID, UUID) -> Void
    /// Tab released outside the window (or well away from the strip), with the
    /// screen point: move it to its own window (or the window it was dropped on).
    var onTearOff: ((UUID, CGPoint) -> Void)? = nil
    /// Chrome layout template: Chrome's curved tabs and widths.
    var chromeStyle = false

    /// The tab being dragged: it lifts off the strip and follows the pointer
    /// while the others slide aside (Helium-style).
    @State private var drag: TabDrag?
    /// Each tab's frame in the strip, for hit-testing the drag.
    @State private var frames: [UUID: CGRect] = [:]
    /// The strip's origin in window coordinates (drags report window points).
    @State private var stripOrigin: CGPoint = .zero
    /// Tab the drag has rested on the middle of; releasing there splits.
    @State private var splitTarget: UUID?
    /// Pending "rested long enough" timer and the tab it's for.
    @State private var dwell: (target: UUID, work: DispatchWorkItem)?
    /// This strip as a drop target for tabs dragged from other windows.
    @StateObject private var zone = TabStripDropZone()
    /// Another window's strip the dragged tab is over.
    @State private var hoveredZone: TabStripDropZone?

    private struct TabDrag {
        let id: UUID
        /// Pointer position minus the tab's origin when the drag began.
        let grab: CGSize
        var pointer: CGPoint
        /// Far enough from the strip that letting go tears the tab off.
        var tearing = false
    }

    /// How far below (or above) the strip a drag has to go to tear off.
    private static let tearOffDistance: CGFloat = 50

    private static let iconTabWidth: CGFloat = 38
    private static let minTabWidth: CGFloat = 72
    private static let maxTabWidth: CGFloat = 220

    var body: some View {
        let ws = store.workspace
        let ids = ws.orderedTabIds()
        let persistent = Set(ws.favorites + ws.activeSpace.pinned.flatMap(\.tabIds))
        GeometryReader { geo in
            let iconCount = ids.filter { persistent.contains($0) }.count
            let titled = ids.count - iconCount
            let iconWidth = chromeStyle ? ChromeMetrics.pinnedTabPitch : Self.iconTabWidth
            let available = geo.size.width - CGFloat(iconCount) * iconWidth - (chromeStyle ? ChromeMetrics.newTabButtonWidth : 34)
            let width = chromeStyle ? ChromeMetrics.tabPitch(available: available, count: titled)
                : titled > 0 ? min(Self.maxTabWidth, max(Self.minTabWidth, available / CGFloat(titled))) : 0
            let minWidth = chromeStyle ? ChromeMetrics.minTabPitch : Self.minTabWidth

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        if let tab = ws.tabs[id] {
                            let iconOnly = persistent.contains(id)
                            let tabWidth = iconOnly ? iconWidth : width
                            let split = ws.splitGroup(containing: id)
                            Color.clear
                                .frame(width: tabWidth, height: height)
                                .overlay {
                                    StripTab(
                                        tab: tab,
                                        faviconURL: web.faviconURLByTab[id] ?? nil,
                                        isActive: ws.activeTabId == id,
                                        isLoading: web.loadingProgressByTab[id] != nil,
                                        iconOnly: iconOnly,
                                        showsSeparator: index > 0 && ws.activeTabId != id && ws.activeTabId != ids[index - 1]
                                            && !(split != nil && split?.panes.contains(ids[index - 1]) == true),
                                        isSplitTarget: splitTarget == id,
                                        inSplit: split != nil,
                                        isVisible: ws.visibleTabIds.contains(id),
                                        onSelect: { onActivate(id) },
                                        onClose: { onClose(id) },
                                        onSplitWithCurrent: ws.activeTabId.flatMap { active in
                                            active != id && !ws.isFavorite(active) && !ws.isFavorite(id) ? { onSplit(id, active) } : nil
                                        },
                                        onRemoveFromSplit: split.map { _ in { store.removeFromSplit(id) } },
                                        chromeStyle: chromeStyle,
                                        chromeShowsClose: ChromeMetrics.showsClose(pitch: tabWidth, isActive: ws.activeTabId == id),
                                        chromeNarrow: !iconOnly && ChromeMetrics.isNarrow(pitch: tabWidth)
                                    )
                                    .frame(width: tabWidth, height: height)
                                    .overlay(TabPressView(
                                        trailingPassthrough: iconOnly ? 0 : 30,
                                        onClick: { onActivate(id) },
                                        onDragChanged: { dragChanged(id, $0) },
                                        onDragEnded: { dragEnded(id, $0) }
                                    ))
                                    .modifier(LiftedTab(offset: liftOffset(for: id), isLifted: drag?.id == id,
                                                        isTearing: drag?.id == id && drag?.tearing == true))
                                }
                                // The slot is measured, not the tab: the lifted tab's offset and scale
                                // would feed back into its own frame and the offset would never settle.
                                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) {
                                    frames[id] = $0
                                    zone.frames[id] = $0
                                }
                                // Chrome's active tab flares over its neighbours.
                                .zIndex(drag?.id == id ? 1 : (chromeStyle && ws.activeTabId == id ? 0.5 : 0))
                        }
                    }
                    if chromeStyle {
                        ChromeNewTabButton(showsSeparator: ids.last != nil && ids.last != ws.activeTabId, action: onNewTab)
                    } else {
                        Button(action: onNewTab) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: height - 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("New Tab (⌘T)")
                        .padding(.leading, 4)
                    }
                }
                .background(NonDraggableWindowView())
                .background(WindowReader { zone.attach(to: $0, store: store) })
                .overlay(alignment: .topLeading) {
                    // Where a tab dragged from another window will land.
                    if let x = zone.markerX {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor)
                            .frame(width: 2, height: height - 8)
                            .offset(x: x - 1, y: 4)
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(.named(Self.space))
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                    stripOrigin = $0.origin
                    zone.bounds = $0
                }
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: ids)
            }
            // The lifted tab can rise a little out of the strip.
            .scrollClipDisabled()
            .scrollDisabled(titled == 0 || CGFloat(titled) * minWidth <= available)
        }
        .frame(height: height)
    }

    private static let space = "luna.tabstrip"

    // MARK: Dragging

    /// Where the lifted tab is drawn relative to its slot: under the pointer
    /// horizontally; vertically it follows with resistance, so it visibly
    /// comes off the strip without covering the page.
    private func liftOffset(for id: UUID) -> CGSize {
        guard let drag, drag.id == id, let frame = frames[id] else { return .zero }
        let dx = drag.pointer.x - drag.grab.width - frame.minX
        let rawY = drag.pointer.y - drag.grab.height - frame.minY
        let dy = (rawY < 0 ? -1 : 1) * min(abs(rawY) * 0.35, 12)
        return CGSize(width: dx, height: dy)
    }

    private func dragChanged(_ id: UUID, _ d: TabPressView.Drag) {
        let point = CGPoint(x: d.windowPoint.x - stripOrigin.x, y: d.windowPoint.y - stripOrigin.y)
        if drag == nil {
            guard let frame = frames[id] else { return }
            onActivate(id)
            drag = TabDrag(id: id, grab: CGSize(width: point.x - frame.minX, height: point.y - frame.minY), pointer: point)
            return
        }
        drag?.pointer = point
        // Over another window's strip: it shows where the tab would land.
        let other = onTearOff == nil ? nil : TabDropTargets.shared.zone(at: d.screenPoint, from: zone.window)
        if hoveredZone !== other {
            hoveredZone?.hover(nil)
            hoveredZone = other
        }
        other?.hover(d.screenPoint)
        let outside = zone.window.map { !$0.frame.contains(d.screenPoint) } ?? false
        let tearing = onTearOff != nil
            && (other != nil || outside || point.y < -Self.tearOffDistance || point.y > height + Self.tearOffDistance)
        if drag?.tearing != tearing {
            withAnimation(.easeOut(duration: 0.15)) { drag?.tearing = tearing }
        }
        // Out of its strip, the tab follows the pointer in a window of its own,
        // so it stays visible over other windows and the desktop.
        if tearing, let tab = store.tab(id) {
            TabDragPreview.shared.show(tab: tab, faviconURL: web.faviconURLByTab[id] ?? nil, at: d.screenPoint)
        } else {
            TabDragPreview.shared.hide()
        }
        if tearing { disarmSplit() } else { track(id, at: point) }
    }

    private func dragEnded(_ id: UUID, _ d: TabPressView.Drag) {
        let tearing = drag?.tearing == true
        hoveredZone?.hover(nil)
        hoveredZone = nil
        TabDragPreview.shared.hide()
        if let target = splitTarget, !tearing { onSplit(id, target) }
        dwell?.work.cancel()
        dwell = nil
        splitTarget = nil
        if tearing, let onTearOff {
            drag = nil
            onTearOff(id, d.screenPoint)
            return
        }
        // Settle into its slot.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = nil }
    }

    /// Reorders live as the dragged tab crosses the edges of the tab under
    /// the pointer; resting on a tab's middle third arms a split.
    private func track(_ dragged: UUID, at point: CGPoint) {
        let live = Set(store.orderedTabIds)
        guard let (target, frame) = frames.first(where: {
            $0.key != dragged && live.contains($0.key) && $0.value.minX <= point.x && point.x < $0.value.maxX
        }) else {
            disarmSplit()
            return
        }
        let t = (point.x - frame.minX) / max(1, frame.width)
        var trial = store.workspace
        if t > 0.3, t < 0.7, frame.width > Self.iconTabWidth, trial.splitTab(dragged, onto: target) != nil {
            // Already armed, or already waiting on this tab.
            guard splitTarget != target, dwell?.target != target else { return }
            disarmSplit()
            let work = DispatchWorkItem { [target] in
                withAnimation(.easeOut(duration: 0.12)) { splitTarget = target }
            }
            dwell = (target, work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            return
        }
        disarmSplit()
        let after = t >= 0.5
        let order = store.orderedTabIds
        guard let from = order.firstIndex(of: dragged), let to = order.firstIndex(of: target),
              after ? from != to + 1 : from != to - 1 else { return }
        store.moveTab(dragged, nextTo: target, after: after)
    }

    private func disarmSplit() {
        dwell?.work.cancel()
        dwell = nil
        if splitTarget != nil { withAnimation(.easeOut(duration: 0.12)) { splitTarget = nil } }
    }

    static func itemProvider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.lunaNode.identifier, visibility: .ownProcess) { done in
            done(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

/// A window's horizontal tab strip as a drop target for tabs dragged out of
/// other windows (Chrome and Helium do the same): which slot a screen point
/// falls in, and the insertion marker shown while a tab hovers there.
final class TabStripDropZone: ObservableObject {
    private(set) weak var window: NSWindow?
    private weak var store: WorkspaceStore?
    /// Tab frames in the strip's own space.
    var frames: [UUID: CGRect] = [:]
    /// The strip in the window, top-left origin (SwiftUI `.global`).
    var bounds: CGRect = .zero
    /// Strip x of the insertion marker, while another window's tab hovers.
    @Published private(set) var markerX: CGFloat?

    /// How far above or below the strip still counts as over it.
    static let slack: CGFloat = 16
    private static let zones = NSMapTable<NSWindow, TabStripDropZone>.weakToWeakObjects()

    static func zone(for window: NSWindow?) -> TabStripDropZone? {
        window.flatMap { zones.object(forKey: $0) }
    }

    func attach(to window: NSWindow?, store: WorkspaceStore) {
        self.store = store
        guard let window, self.window !== window else { return }
        self.window = window
        Self.zones.setObject(self, forKey: window)
    }

    /// A screen point in the strip's space, if it's over the strip.
    func stripPoint(fromScreen p: CGPoint) -> CGPoint? {
        guard let window, window.isVisible else { return nil }
        let w = window.convertPoint(fromScreen: p)
        let local = CGPoint(x: w.x - bounds.minX, y: window.frame.height - w.y - bounds.minY)
        guard local.x >= 0, local.x <= bounds.width,
              local.y >= -Self.slack, local.y <= bounds.height + Self.slack else { return nil }
        return local
    }

    /// Where a tab dropped at strip x lands: beside which tab, on which side,
    /// and the x of that edge.
    func insertion(atX x: CGFloat) -> (target: UUID, after: Bool, edge: CGFloat)? {
        let slots = (store?.orderedTabIds ?? []).compactMap { id in frames[id].map { (id: id, frame: $0) } }
        guard let last = slots.last else { return nil }
        guard let slot = slots.first(where: { x < $0.frame.maxX }) else {
            return (last.id, true, last.frame.maxX)
        }
        let after = x >= slot.frame.midX
        return (slot.id, after, after ? slot.frame.maxX : slot.frame.minX)
    }

    func insertion(atScreen p: CGPoint) -> (target: UUID, after: Bool)? {
        stripPoint(fromScreen: p).flatMap { insertion(atX: $0.x) }.map { ($0.target, $0.after) }
    }

    /// Shows (or, with nil, hides) the marker for a hovering tab.
    func hover(_ screenPoint: CGPoint?) {
        let x = screenPoint.flatMap(stripPoint(fromScreen:)).flatMap { insertion(atX: $0.x)?.edge }
        if markerX != x { markerX = x }
    }
}

/// The tab under the pointer while it's dragged out of its strip: a small
/// click-through window, so it shows over other windows (Chrome uses a
/// drag window the same way).
final class TabDragPreview {
    static let shared = TabDragPreview()
    private var panel: NSPanel?
    private var shownTab: UUID?
    private static let size = CGSize(width: 200, height: 30)

    func show(tab: Tab, faviconURL: URL?, at screenPoint: CGPoint) {
        let panel = self.panel ?? makePanel()
        if shownTab != tab.id {
            shownTab = tab.id
            panel.contentView = NSHostingView(rootView: Label(tab: tab, faviconURL: faviconURL))
        }
        // Pointer near the tab's leading edge, as where it was grabbed.
        panel.setFrameOrigin(NSPoint(x: screenPoint.x - 24, y: screenPoint.y - Self.size.height / 2))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel?.orderOut(nil)
        shownTab = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        self.panel = panel
        return panel
    }

    private struct Label: View {
        let tab: Tab
        let faviconURL: URL?

        var body: some View {
            HStack(spacing: 6) {
                TabIcon(tab: tab, faviconURL: faviconURL).frame(width: 16, height: 16)
                Text(displayTitle(for: tab))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: TabDragPreview.size.width, height: TabDragPreview.size.height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Reports the window a view is in, as it moves between windows.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { onWindow(window) }
    }
}

extension UTType {
    /// In-app drag type for tabs (same identifier as the sidebar's pasteboard type).
    static let lunaNode = UTType(exportedAs: "com.luna.browser.node")
}

private struct StripTab: View {
    let tab: Tab
    let faviconURL: URL?
    let isActive: Bool
    let isLoading: Bool
    let iconOnly: Bool
    let showsSeparator: Bool
    var isSplitTarget = false
    var inSplit = false
    var isVisible = false
    let onSelect: () -> Void
    let onClose: () -> Void
    var onSplitWithCurrent: (() -> Void)?
    var onRemoveFromSplit: (() -> Void)?
    var chromeStyle = false
    var chromeShowsClose = true
    var chromeNarrow = false

    @State private var isHovered = false

    var body: some View {
        content
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .help(displayTitle(for: tab))
            .contextMenu {
                if let onSplitWithCurrent {
                    Button("Open in Split View with Current Tab", action: onSplitWithCurrent)
                }
                if let onRemoveFromSplit {
                    Button("Remove from Split View", action: onRemoveFromSplit)
                }
                Button("Close Tab", action: onClose)
            }
    }

    @ViewBuilder
    private var content: some View {
        if chromeStyle {
            ChromeTabView(tab: tab, faviconURL: faviconURL, isActive: isActive, isLoading: isLoading, iconOnly: iconOnly,
                          showsSeparator: showsSeparator && !isHovered, showsClose: chromeShowsClose,
                          isHovered: isHovered || isVisible, narrow: chromeNarrow, onClose: onClose)
                .overlay { splitTargetMark }
        } else {
            lunaTab
        }
    }

    @ViewBuilder
    private var splitTargetMark: some View {
        if isSplitTarget {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                .overlay(Image(systemName: "rectangle.split.2x1").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor))
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
                .allowsHitTesting(false)
        }
    }

    private var lunaTab: some View {
        HStack(spacing: 6) {
            ZStack {
                TabIcon(tab: tab, faviconURL: faviconURL)
                    .opacity(isLoading ? 0.35 : 1)
                if isLoading { ProgressView().controlSize(.mini) }
            }
            .frame(width: 16, height: 16)
            if !iconOnly {
                Text(displayTitle(for: tab))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isActive ? 1 : 0)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, iconOnly ? 0 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                // Split partners on screen get a lighter fill than the focused pane.
                .fill(.quaternary.opacity(isActive ? 1 : (isVisible ? 0.6 : (isHovered ? 0.5 : 0))))
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
        )
        // Drop here to open side by side.
        .overlay { splitTargetMark }
        .overlay(alignment: .leading) {
            if showsSeparator {
                Rectangle().fill(.separator).frame(width: 1, height: 14)
            }
        }
    }
}

/// Chrome's "+" after the last tab, with the separator before it.
private struct ChromeNewTabButton: View {
    let showsSeparator: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        let palette = ChromePalette.for(scheme)
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(palette.icon)
                .frame(width: 28, height: 28)
                .background(Circle().fill(palette.hover.opacity(isHovering ? 1.5 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("New Tab (⌘T)")
        .padding(.leading, 3)
        .overlay(alignment: .topLeading) {
            if showsSeparator {
                Rectangle().fill(palette.tabSeparator).frame(width: 1, height: 16).offset(x: -0.5, y: 6)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, ChromeMetrics.tabTop)
    }
}

/// The dragged tab: lifted above its neighbours with a soft shadow, drawn
/// at the pointer, and kept out of the slide animation the others use.
private struct LiftedTab: ViewModifier {
    let offset: CGSize
    let isLifted: Bool
    /// Pulled away from the strip: shown smaller and faded, about to tear off.
    var isTearing = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
                    .padding(.vertical, 2)
                    .opacity(isLifted ? 1 : 0)
            )
            .scaleEffect(isTearing ? 0.9 : (isLifted ? 1.04 : 1))
            // The drag preview window carries it now.
            .opacity(isTearing ? 0.3 : 1)
            .shadow(color: .black.opacity(isLifted ? 0.28 : 0), radius: 10, y: 4)
            .offset(offset)
            .zIndex(isLifted ? 1 : 0)
            .transaction { if isLifted { $0.animation = nil } }
    }
}
