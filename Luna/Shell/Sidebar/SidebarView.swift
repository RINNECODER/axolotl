import SwiftUI
import UniformTypeIdentifiers

/// Arc-style sidebar: window controls and navigation, favorites, the
/// pinned/today outline, and the space bar. The URL field lives in the
/// top bar that slides in on hover or ⌘L.
struct SidebarView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var web: WebViewWrapper
    let isFullScreen: Bool
    let actions: SidebarActions
    let onToggleSidebar: () -> Void
    let extensions: ExtensionHost
    /// Profile switcher, supplied by the shell (it owns profile state).
    let profileControl: AnyView

    static let topRowHeight: CGFloat = 38

    private var activeTab: Tab? { store.activeTabId.flatMap(store.tab) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            FavoritesGrid(store: store, web: web, actions: actions)
            SidebarOutline(snapshot: .make(store: store, web: web), actions: actions)
                // Source-list rows carry their own inset; line them up with the URL field.
                .padding(.horizontal, -8)
            bottomBar
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    @AppStorage(ChromePrefs.showToolbar) private var showToolbar = false

    // MARK: Top row

    private var topRow: some View {
        HStack(spacing: 2) {
            // Leave room for the traffic lights.
            Spacer().frame(width: isFullScreen ? 0 : 70)
            ToolbarIconButton(systemName: "sidebar.left", help: "Hide Sidebar (⌘S)", action: onToggleSidebar)
            Spacer(minLength: 0)
            // With the toolbar on, navigation lives there instead.
            if !showToolbar {
                ToolbarIconButton(systemName: "chevron.left", help: "Back", isEnabled: web.canGoBackForActiveTab) {
                    if let id = store.activeTabId { web.goBack(in: id) }
                }
                ToolbarIconButton(systemName: "chevron.right", help: "Forward", isEnabled: web.canGoForwardForActiveTab) {
                    if let id = store.activeTabId { web.goForward(in: id) }
                }
                ToolbarIconButton(systemName: "arrow.clockwise", help: "Reload (⌘R)") {
                    if let id = store.activeTabId { web.reload(in: id) }
                }
            }
        }
        .frame(height: Self.topRowHeight)
        .background(WindowDragRegionView())
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 4) {
            profileControl
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(store.workspace.spaces) { space in
                    let isActive = space.id == store.workspace.activeSpaceId
                    Button { store.switchSpace(space.id) } label: {
                        Image(systemName: space.icon)
                            .font(.system(size: isActive ? 11 : 7, weight: .semibold))
                            .foregroundStyle(isActive ? .primary : .tertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(space.name)
                    .lunaContextMenu {
                        var entries: [LunaMenuEntry] = [
                            .button("Rename Space…") {
                                if let name = TextPrompt.name(title: "Rename Space", initial: space.name) {
                                    store.updateSpace(space.id) { $0.name = name }
                                }
                            },
                        ]
                        if store.workspace.spaces.count > 1 {
                            entries.append(.button("Delete Space", destructive: true) {
                                store.deleteSpace(space.id).forEach { web.removeWebView(for: $0) }
                            })
                        }
                        return entries
                    }
                }
            }
            ToolbarIconButton(systemName: "plus", help: "New Space") {
                if let name = TextPrompt.name(title: "New Space", initial: "Space \(store.workspace.spaces.count + 1)") {
                    store.createSpace(name: name)
                    actions.newTab()
                }
            }
            SidebarMoreMenu(extensions: extensions, bookmarkPage: actions.bookmarkPage)
            DownloadsButton()
        }
        .frame(height: 28)
    }
}

// MARK: - Favorites

/// Favorites as icon tiles. Drag to reorder, drag a tab in from the list to
/// add it, or drag a favorite out onto the list to make it a regular tab.
private struct FavoritesGrid: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var web: WebViewWrapper
    let actions: SidebarActions

    /// Favorite being dragged from this grid (nil for drags from the list).
    @State private var dragging: UUID?
    @State private var emptyTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 48), spacing: 6)]

    var body: some View {
        let favorites = store.workspace.favorites
        if favorites.isEmpty {
            // Thin landing strip: grows into a hint while a tab hovers it.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.tertiary)
                .overlay(Text("Add to Favorites").font(.system(size: 11)).foregroundStyle(.secondary))
                .frame(height: emptyTargeted ? 40 : 10)
                .opacity(emptyTargeted ? 1 : 0)
                .contentShape(Rectangle())
                .onDrop(of: [.lunaNode], isTargeted: $emptyTargeted) { providers in
                    FavoriteDrop.load(providers) { store.moveToFavorites($0, at: 0) }
                }
                .animation(.easeOut(duration: 0.15), value: emptyTargeted)
        } else {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(favorites, id: \.self) { id in
                    if let tab = store.tab(id) {
                        tile(id: id, tab: tab)
                            .onDrag {
                                dragging = id
                                return HorizontalTabStrip.itemProvider(for: id)
                            }
                            .onDrop(of: [.lunaNode], delegate: FavoriteDrop(target: id, store: store, dragging: $dragging))
                    }
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.86), value: favorites)
        }
    }

    private func tile(id: UUID, tab: Tab) -> some View {
        let isActive = store.activeTabId == id
        return Button { actions.activate(id) } label: {
            TabIcon(tab: tab, faviconURL: web.faviconURLByTab[id] ?? nil, size: 18)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isActive ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.quaternary.opacity(0.6)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(displayTitle(for: tab))
        .lunaContextMenu {
            [
                .button("Remove from Favorites") { store.unpin(id) },
                .button("Reset Tab") { actions.close(id) },
            ]
        }
    }
}

/// Reorders favorites live while one is dragged across the grid; tabs dragged
/// in from the list are added where they're dropped.
private struct FavoriteDrop: DropDelegate {
    let target: UUID
    let store: WorkspaceStore
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragged = dragging, dragged != target,
              let to = store.workspace.favorites.firstIndex(of: target) else { return }
        store.moveToFavorites(dragged, at: to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil }
        guard dragging == nil else { return true }
        return Self.load(info.itemProviders(for: [.lunaNode])) { id in
            store.moveToFavorites(id, at: store.workspace.favorites.firstIndex(of: target))
        }
    }

    /// Reads a dragged tab id (from the grid, the tab strip or the sidebar list).
    @discardableResult
    static func load(_ providers: [NSItemProvider], then action: @escaping (UUID) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.lunaNode.identifier) { data, _ in
            guard let data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return }
            DispatchQueue.main.async { action(id) }
        }
        return true
    }
}

// MARK: - ⋯ menu

/// Sidebar's ⋯ menu: bookmark this page, extensions and settings.
private struct SidebarMoreMenu: View {
    let extensions: ExtensionHost
    let bookmarkPage: (() -> Void)?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        LunaMenuButton(alignment: .leading, minWidth: 220, help: "More", opensAbove: true, debugID: "sidebar.more", items: {
            let settings = LunaSettingsOpener(openSettings: openSettings)
            return [.button("Bookmark This Page", icon: "star", shortcut: "⌘D", enabled: bookmarkPage != nil) { bookmarkPage?() },
                    .divider("b")]
                + ExtensionMenuEntries.build(host: extensions, settings: settings, icon: "puzzlepiece.extension")
                + [.divider("s"), .button("Settings", icon: "gearshape", shortcut: "⌘,") { settings() }]
        }) { isOpen in
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(LunaSurface.hover.opacity(isOpen ? 1 : 0)))
                .contentShape(Rectangle())
        }
        .fixedSize()
        .background(PopupAnchor { extensions.menuAnchor = $0 })
    }
}

// MARK: - Toolbar button

/// Borderless toolbar-style icon button with the system hover background.
struct ToolbarIconButton: View {
    let systemName: String
    let help: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? .secondary : .quaternary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary.opacity(isHovering && isEnabled ? 1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Resize handle

/// Invisible strip on the sidebar's trailing edge; drag to resize.
struct SidebarResizeHandle: View {
    @Binding var width: Double
    static let range: ClosedRange<Double> = 180...420

    @State private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(max(start + value.translation.width, Self.range.lowerBound), Self.range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .offset(x: 3)
    }
}
