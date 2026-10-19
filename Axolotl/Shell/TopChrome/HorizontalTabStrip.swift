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
    /// Tab menu: move the tab (or, with true, its group) to a new window.
    var onMoveToNewWindow: ((UUID, Bool) -> Void)? = nil
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
        let groupOf = Dictionary(ws.tabGroups.flatMap { g in g.tabIds.map { ($0, g) } }, uniquingKeysWith: { a, _ in a })
        // A collapsed group hides its tabs behind the chip (the active tab stays, as in Chrome).
        let ids = ws.orderedTabIds().filter { id in groupOf[id].map { $0.isExpanded || ws.activeTabId == id } ?? true }
        let chipIds = ws.tabGroups.compactMap(\.tabIds.first)
        let persistent = Set(ws.favorites + ws.activeSpace.pinned.flatMap(\.tabIds))
        GeometryReader { geo in
            let iconCount = ids.filter { persistent.contains($0) }.count
            let titled = ids.count - iconCount
            let iconWidth = chromeStyle ? ChromeMetrics.pinnedTabPitch : Self.iconTabWidth
            let chipsWidth = ws.tabGroups.reduce(CGFloat(0)) { $0 + TabGroupChip.width(for: $1.name) }
            let available = geo.size.width - CGFloat(iconCount) * iconWidth - chipsWidth
                - (chromeStyle ? ChromeMetrics.newTabButtonWidth : 34)
            let width = chromeStyle ? ChromeMetrics.tabPitch(available: available, count: titled)
                : titled > 0 ? min(Self.maxTabWidth, max(Self.minTabWidth, available / CGFloat(titled))) : 0
            let minWidth = chromeStyle ? ChromeMetrics.minTabPitch : Self.minTabWidth

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(ws.orderedTabIds().enumerated()), id: \.element) { _, id in
                      HStack(spacing: 0) {
                        if chipIds.contains(id), let group = groupOf[id] {
                            TabGroupChip(group: group, height: height,
                                         onToggle: { store.setFolderExpanded(group.id, !group.isExpanded) },
                                         menu: { TabGroupChip.menu(for: group, store: store, close: onClose,
                                                                    moveToNewWindow: onMoveToNewWindow) })
                        }
                        if let tab = ws.tabs[id], let index = ids.firstIndex(of: id) {
                            let iconOnly = persistent.contains(id)
                            let tabWidth = iconOnly ? iconWidth : width
                            let split = ws.splitGroup(containing: id)
                            Color.clear
                                .frame(width: tabWidth, height: height)
                                .overlay {
                                  TabRuntimeReader(state: web.tabRuntime.state(for: id)) { runtime in
                                    StripTab(
                                        tab: tab,
                                        faviconURL: runtime.faviconURL,
                                        isActive: ws.activeTabId == id,
                                        isLoading: runtime.isLoading,
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
                                        chromeNarrow: !iconOnly && ChromeMetrics.isNarrow(pitch: tabWidth),
                                        audio: TabAudioState(web: web, tabId: id),
                                        menuItems: { TabContextMenu.items(for: id, store: store, web: web, close: onClose,
                                                                                   moveToNewWindow: onMoveToNewWindow) }
                                    )
                                    .frame(width: tabWidth, height: height)
                                    .overlay(TabPressView(
                                        trailingPassthrough: iconOnly ? 0 : (TabAudioState(web: web, tabId: id).isShown ? 56 : 30),
                                        onClick: { onActivate(id) },
                                        onDragChanged: { dragChanged(id, $0) },
                                        onDragEnded: { dragEnded(id, $0) }
                                    ))
                                    .modifier(LiftedTab(offset: liftOffset(for: id), isLifted: drag?.id == id,
                                                        isTearing: drag?.id == id && drag?.tearing == true))
                                  }
                                }
                                // The slot is measured, not the tab: the lifted tab's offset and scale
                                // would feed back into its own frame and the offset would never settle.
                                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) {
                                    frames[id] = $0
                                    zone.frames[id] = $0
                                }
                                .overlay(alignment: .bottom) {
                                    if let group = groupOf[id] {
                                        Rectangle().fill(group.groupColor.swatch).frame(height: 2).allowsHitTesting(false)
                                    }
                                }
                                .onDisappear { frames[id] = nil; zone.frames[id] = nil }
                        }
                      }
                      // Chrome's active tab flares over its neighbours.
                      .zIndex(drag?.id == id ? 1 : (chromeStyle && ws.activeTabId == id ? 0.5 : 0))
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
                        .accessibilityLabel("New Tab")
                        .padding(.leading, 4)
                    }
                }
                .background(NonDraggableWindowView())
                .background(WindowReader { zone.attach(to: $0, store: store) })
                .overlay(alignment: .topLeading) {
                    // Where a tab dragged from another window will land.
                    if let x = zone.markerX {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(AxolotlSurface.accent)
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

    private static let space = "axolotl.tabstrip"

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
            TabDragPreview.shared.show(tab: tab, faviconURL: web.faviconURL(for: id), at: d.screenPoint)
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
        provider.registerDataRepresentation(forTypeIdentifier: UTType.axolotlNode.identifier, visibility: .ownProcess) { done in
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
            .background(AxolotlMaterialFill(shape: RoundedRectangle(cornerRadius: 8, style: .continuous), surface: .toolbar))
        }
    }
}

/// Chrome's tab hover card: full title and host under the hovered tab, in a click-through child window.
@MainActor
final class TabHoverCard {
    static let shared = TabHoverCard()
    private var panel: NSPanel?
    private var shownTab: UUID?

    /// `frame` is the tab in its window's SwiftUI global space.
    func show(tab: Tab, below frame: CGRect) {
        let mouse = NSEvent.mouseLocation
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        // shortcut: assumes the shell's hosting view is the window's content view (true for browser windows).
        guard let window = NSApp.window(withWindowNumber: number), let content = window.contentView else { return }
        let panel = self.panel ?? makePanel()
        let host = NSHostingView(rootView: Card(title: displayTitle(for: tab), host: tab.url?.host.map(SiteShortcut.normalizedHost) ?? ""))
        host.appearance = window.effectiveAppearance
        let size = host.fittingSize
        panel.contentView = host
        let anchor = window.convertToScreen(content.convert(NSRect(x: frame.minX, y: frame.maxY, width: 0, height: 0), to: nil))
        panel.setFrame(NSRect(x: anchor.minX, y: anchor.minY - 4 - size.height, width: size.width, height: size.height), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        shownTab = tab.id
    }

    /// Hides the card if it's showing `tabId`.
    func hide(_ tabId: UUID) {
        guard shownTab == tabId, let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        shownTab = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    struct Card: View {
        let title: String
        let host: String

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !host.isEmpty {
                    Text(host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: 240, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AxolotlSurface.raised))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AxolotlSurface.stroke))
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
    static let axolotlNode = UTType(exportedAs: "com.axolotl.browser.node")
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
    var audio = TabAudioState.silent
    /// The shared tab menu (Chrome's items), after the split items.
    var menuItems: () -> [[TabContextMenu.Item]] = { [] }

    @State private var isHovered = false

    var body: some View {
        content
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            // Hover card after 500 ms (Chrome); the task only exists while hovering.
            .background {
                GeometryReader { geo in
                    Color.clear.task(id: isHovered) {
                        guard isHovered else { TabHoverCard.shared.hide(tab.id); return }
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        TabHoverCard.shared.show(tab: tab, below: geo.frame(in: .global))
                    }
                }
            }
            .onDisappear { TabHoverCard.shared.hide(tab.id) }
            .accessibilityHint(displayTitle(for: tab))
            .axolotlContextMenu {
                var entries: [AxolotlMenuEntry] = []
                if let onSplitWithCurrent {
                    entries.append(.button("Open in Split View with Current Tab", icon: "rectangle.split.2x1",
                                           action: onSplitWithCurrent))
                }
                if let onRemoveFromSplit {
                    entries.append(.button("Remove from Split View", icon: "rectangle", action: onRemoveFromSplit))
                }
                return TabContextMenu.axolotlEntries(menuItems(), leading: entries)
            }
    }

    @ViewBuilder
    private var content: some View {
        if chromeStyle {
            ChromeTabView(tab: tab, faviconURL: faviconURL, isActive: isActive, isLoading: isLoading, iconOnly: iconOnly,
                          showsSeparator: showsSeparator && !isHovered, showsClose: chromeShowsClose,
                          isHovered: isHovered || isVisible, narrow: chromeNarrow, audio: audio, onClose: onClose)
                .overlay { splitTargetMark }
        } else {
            axolotlTab
        }
    }

    @ViewBuilder
    private var splitTargetMark: some View {
        if isSplitTarget {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AxolotlSurface.accent, lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AxolotlSurface.accent.opacity(0.12)))
                .overlay(Image(systemName: "rectangle.split.2x1").font(.system(size: 11, weight: .semibold)).foregroundStyle(AxolotlSurface.accent))
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
                .allowsHitTesting(false)
        }
    }

    private var axolotlTab: some View {
        HStack(spacing: 6) {
            ZStack {
                TabIcon(tab: tab, faviconURL: faviconURL)
                    .opacity(isLoading ? 0.35 : 1)
                if isLoading { ProgressView().controlSize(.mini) }
            }
            .frame(width: 16, height: 16)
            if !iconOnly {
                Text(displayTitle(for: tab))
                    .font(.system(size: ThemeStore.shared.theme.font(12)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isActive ? .primary : AxolotlSurface.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TabAudioButton(audio: audio)
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
                .accessibilityLabel("Close Tab")
            }
        }
        .padding(.horizontal, iconOnly ? 0 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: ThemeStore.shared.theme.radius(8), style: .continuous)
                // Split partners on screen get a lighter fill than the focused pane.
                .fill(isActive ? AnyShapeStyle(AxolotlSurface.activeTab)
                      : AnyShapeStyle(.quaternary.opacity(isVisible ? 0.6 : (isHovered ? 0.5 : 0))))
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
        .accessibilityLabel("New Tab")
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
                AxolotlMaterialFill(shape: RoundedRectangle(cornerRadius: 8, style: .continuous), surface: .toolbar)
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


// MARK: - Tab groups

extension TabGroupColor {
    /// Chrome's group colors.
    var swatch: Color {
        switch self {
        case .grey: return Color(red: 0.37, green: 0.39, blue: 0.41)
        case .blue: return Color(red: 0.10, green: 0.45, blue: 0.91)
        case .red: return Color(red: 0.85, green: 0.19, blue: 0.15)
        case .yellow: return Color(red: 0.98, green: 0.67, blue: 0.0)
        case .green: return Color(red: 0.12, green: 0.56, blue: 0.24)
        case .pink: return Color(red: 0.82, green: 0.09, blue: 0.52)
        case .purple: return Color(red: 0.58, green: 0.20, blue: 0.90)
        case .cyan: return Color(red: 0.0, green: 0.48, blue: 0.51)
        case .orange: return Color(red: 0.98, green: 0.56, blue: 0.24)
        }
    }
}

/// Chrome's group chip: a colored pill (a dot when unnamed) before the group's tabs;
/// click collapses or expands the group.
struct TabGroupChip: View {
    let group: Folder
    let height: CGFloat
    let onToggle: () -> Void
    let menu: () -> [AxolotlMenuEntry]

    static func width(for name: String) -> CGFloat {
        name.isEmpty ? 28 : min(140, 24 + CGFloat(name.count) * 7)
    }

    var body: some View {
        let color = group.groupColor.swatch
        Button(action: onToggle) {
            Group {
                if group.name.isEmpty {
                    Circle().fill(color).frame(width: 10, height: 10)
                } else {
                    Text(group.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(color))
                }
            }
            .frame(width: Self.width(for: group.name), height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            // The underline starts under the chip and runs on under the group's tabs.
            if group.isExpanded { Rectangle().fill(color).frame(height: 2).padding(.leading, 6) }
        }
        .accessibilityLabel(TabContextMenu.groupTitle(group.name) + " tab group")
        .accessibilityValue(group.isExpanded ? "Expanded" : "Collapsed")
        .help(group.isExpanded ? "Collapse group" : "Expand group")
        .axolotlContextMenu { menu() }
    }

    /// Chrome's group menu: rename, color, ungroup, close group.
    static func menu(for group: Folder, store: WorkspaceStore, close: @escaping (UUID) -> Void,
                     moveToNewWindow: ((UUID, Bool) -> Void)? = nil) -> [AxolotlMenuEntry] {
        var entries: [AxolotlMenuEntry] = [
            .button("Rename Group…", icon: "pencil") {
                if let name = TextPrompt.name(title: "Name This Group", initial: group.name) { store.renameFolder(group.id, to: name) }
            },
            .submenu("Color", icon: "paintpalette", TabGroupColor.allCases.map { c in
                .button(c.rawValue.capitalized, checked: c == group.groupColor) { store.setTabGroupColor(group.id, c) }
            }),
            .divider("group.1"),
            .button("New Tab in Group", icon: "plus") {
                let id = store.newTab(url: nil)
                store.addToTabGroup(id, group: group.id)
            },
            .button("Ungroup", icon: "square.dashed") { store.ungroupFolder(group.id) },
            .button("Close Group", icon: "xmark", destructive: true) { store.closeTabGroup(group.id, closingWith: close) },
        ]
        if let moveToNewWindow, let first = group.tabIds.first, group.tabIds.count < store.orderedTabIds.count {
            entries.insert(.button(TabContextMenu.Command.moveGroupToNewWindow.title, icon: "macwindow.badge.plus") {
                moveToNewWindow(first, true)
            }, at: entries.count - 1)
        }
        return entries
    }
}
