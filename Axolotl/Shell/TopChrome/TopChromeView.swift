import SwiftUI

/// Callbacks the top chrome needs from the shell.
struct TopChromeActions {
    var activate: (UUID) -> Void
    var close: (UUID) -> Void
    var newTab: () -> Void
    /// Dropped tab, target tab: open them in split view.
    var split: (UUID, UUID) -> Void
    /// Tab dragged out of the strip, released at a screen point.
    var tearOff: (UUID, CGPoint) -> Void = { _, _ in }
    /// Tab menu: move the tab (or, with true, its group) to a new window.
    var moveToNewWindow: (UUID, Bool) -> Void = { _, _ in }
    var submitAddress: () -> Void
    var goHome: () -> Void
    var toggleAI: () -> Void
    var showDownloads: () -> Void
    var showPasswords: () -> Void = {}
    var showHistory: () -> Void
    var askOnPage: () -> Void = {}
    var canAskOnPage: Bool = true
    var bookmarkPage: () -> Void = {}
    var newWindow: () -> Void = {}
    /// Current tab's zoom (1.0 = 100%); nil when the tab has no web page.
    var zoomLevel: () -> CGFloat? = { nil }
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var printPage: () -> Void = {}
    var findInPage: () -> Void = {}
    var toggleFullScreen: () -> Void = {}
}

/// The app menu (⋯ / ⋮) as Axolotl menu rows, following Chrome's order where
/// Axolotl has the same command.
enum AppMenuEntries {
    @MainActor
    static func build(actions: TopChromeActions, extensions: ExtensionHost, settings: AxolotlSettingsOpener) -> [AxolotlMenuEntry] {
        let zoom = actions.zoomLevel()
        let showBar = UserDefaults.standard.bool(forKey: ChromePrefs.showBookmarksBar)
        var entries: [AxolotlMenuEntry] = [
            .button("New tab", icon: "plus.square.on.square", shortcut: "⌘T", action: actions.newTab),
            .button("New window", icon: "macwindow.badge.plus", action: actions.newWindow),
            .divider("s1"),
            .button("Ask on Page", icon: "sparkles", enabled: actions.canAskOnPage, action: actions.askOnPage),
            .divider("s2"),
            .button("History", icon: "clock.arrow.circlepath", shortcut: "⌘Y", action: actions.showHistory),
            .button("Downloads", icon: "arrow.down.to.line", action: actions.showDownloads),
            .button("Passwords", icon: "key", action: actions.showPasswords),
            .submenu("Bookmarks and lists", icon: "star", [
                .button("Bookmark this tab…", icon: "star", shortcut: "⌘D", action: actions.bookmarkPage),
                .button(showBar ? "Hide bookmarks bar" : "Show bookmarks bar", icon: "menubar.rectangle") {
                    UserDefaults.standard.set(!showBar, forKey: ChromePrefs.showBookmarksBar)
                },
            ]),
        ]
        entries += ExtensionMenuEntries.build(host: extensions, settings: settings, icon: "puzzlepiece.extension")
        entries.append(.divider("s3"))
        entries.append(.zoom(AxolotlMenuZoom(
            level: zoom.map { "\(Int(($0 * 100).rounded()))%" } ?? "100%",
            zoomOut: actions.zoomOut, zoomIn: actions.zoomIn, fullScreen: actions.toggleFullScreen)))
        entries += [
            .divider("s4"),
            .button("Print…", icon: "printer", shortcut: "⌘P", enabled: zoom != nil, action: actions.printPage),
            .button("Find…", icon: "doc.text.magnifyingglass", shortcut: "⌘F", enabled: zoom != nil,
                    action: actions.findInPage),
            .divider("s5"),
            .button("Settings", icon: "gearshape", shortcut: "⌘,") { settings() },
        ]
        return entries
    }
}

/// Window chrome for the Compact, Dynamic and Classic layouts.
struct TopChromeView: View {
    let layout: BrowserLayout
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var web: WebViewWrapper
    @Binding var addressText: String
    var addressFocused: FocusState<Bool>.Binding
    /// No window buttons share this row (a docked sidebar holds them), so it needs no inset.
    let omitsWindowButtonInset: Bool
    /// False in frameless mode: tabs live in the edge-revealed list instead.
    let showsTabs: Bool
    let profileControl: AnyView
    let extensions: ExtensionHost
    let actions: TopChromeActions
    /// Chrome layout template (Classic layout only): Chrome's tab strip and toolbar.
    var chromeStyle = false
    /// For the omnibox star.
    var bookmarks: BookmarkStore?

    @Environment(\.colorScheme) private var scheme
    @AppStorage(ChromePrefs.centeredAddressBar) private var centeredAddressBar = false
    @AppStorage(ChromePrefs.showHomeButton) private var showHomeButton = false

    static let rowHeight: CGFloat = 40
    static let tabRowHeight: CGFloat = 36

    private var trafficLightInset: CGFloat { omitsWindowButtonInset ? 8 : 78 }
    private var activeURL: URL? { store.activeTabId.flatMap { store.tab($0)?.url } }

    /// Height of the chrome for a layout, used to place the content below it.
    static func height(for layout: BrowserLayout, showsTabs: Bool) -> CGFloat {
        switch layout {
        case .sidebar: return 0
        case .compact: return rowHeight
        case .dynamic, .classic: return showsTabs ? rowHeight + tabRowHeight : rowHeight
        }
    }

    var body: some View {
        if chromeStyle && layout == .classic {
            chromeBody.background(WindowDragRegionView())
        } else {
            axolotlBody
        }
    }

    private var axolotlBody: some View {
        Group {
            switch layout {
            case .classic where showsTabs:
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Spacer().frame(width: trafficLightInset)
                        tabStrip
                    }
                    .frame(height: Self.tabRowHeight)
                    .padding(.trailing, 8)
                    navigationRow(leadingInset: 8)
                }
            case .dynamic where showsTabs:
                VStack(spacing: 0) {
                    navigationRow(leadingInset: trafficLightInset)
                    tabStrip
                        .frame(height: Self.tabRowHeight)
                        .padding(.horizontal, 8)
                }
            case .compact where showsTabs:
                HStack(spacing: 6) {
                    Spacer().frame(width: trafficLightInset)
                    navButtons
                    address
                        .frame(minWidth: 180, idealWidth: 320, maxWidth: 360)
                    tabStrip
                        .frame(maxWidth: .infinity)
                    toolbarIcons
                }
                .padding(.horizontal, 8)
                .frame(height: Self.rowHeight)
            default:
                navigationRow(leadingInset: trafficLightInset)
            }
        }
        .background(WindowDragRegionView())
    }

    // MARK: Chrome template

    private var chromeBody: some View {
        let palette = ChromePalette.for(scheme)
        return VStack(spacing: 0) {
            if showsTabs {
                HStack(spacing: 0) {
                    Spacer().frame(width: omitsWindowButtonInset ? 8 : ChromeMetrics.tabSearchLeading)
                    ChromeTabSearchButton(store: store, onActivate: actions.activate)
                        .padding(.top, ChromeMetrics.tabTop)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(NonDraggableWindowView())
                    Spacer().frame(width: 3)
                    HorizontalTabStrip(
                        store: store, web: web, height: ChromeMetrics.tabStripHeight,
                        onActivate: actions.activate, onClose: actions.close, onNewTab: actions.newTab,
                        onSplit: actions.split, onTearOff: actions.tearOff, onMoveToNewWindow: actions.moveToNewWindow,
                        chromeStyle: true
                    )
                    .padding(.trailing, 8)
                }
                .frame(height: ChromeMetrics.tabStripHeight)
                .background(palette.frame)
            }
            HStack(spacing: 2) {
                ChromeToolbarButton(systemName: "arrow.left", help: "Back (⌘[)", isEnabled: web.canGoBackForActiveTab) {
                    if let id = store.activeTabId { web.goBack(in: id) }
                }
                ChromeToolbarButton(systemName: "arrow.right", help: "Forward (⌘])", isEnabled: web.canGoForwardForActiveTab) {
                    if let id = store.activeTabId { web.goForward(in: id) }
                }
                ChromeToolbarButton(systemName: "arrow.clockwise", help: "Reload (⌘R)") {
                    if let id = store.activeTabId { web.reload(in: id) }
                }
                if showHomeButton {
                    ChromeToolbarButton(systemName: "house", help: "Home", action: actions.goHome)
                }
                TabRuntimeReader(state: web.tabRuntime.state(for: store.activeTabId)) { runtime in
                AddressField(
                    url: activeURL,
                    text: $addressText,
                    focused: addressFocused,
                    loadingProgress: runtime.loadingProgress,
                    height: ChromeMetrics.omniboxHeight,
                    chromeStyle: true,
                    trailing: AnyView(ChromeStar(url: activeURL, bookmarks: bookmarks, add: actions.bookmarkPage)),
                    web: web,
                    onSubmit: actions.submitAddress
                )
                .padding(.horizontal, 7)
                }
                ShieldsButton(web: web, extensions: extensions, tabId: store.activeTabId, url: activeURL)
                ChromeToolbarButton(systemName: "sparkles", help: "Axolotl AI (⌘E)", action: actions.toggleAI)
                ChromeExtensionsButton(extensions: extensions)
                DownloadsButton()
                profileControl
                    .frame(width: ChromeMetrics.toolbarButton, height: ChromeMetrics.toolbarButton)
                ChromeMenuButton(actions: actions, extensions: extensions)
            }
            .padding(.horizontal, 6)
            .frame(height: ChromeMetrics.toolbarHeight)
            .background(palette.toolbar)
            .background(NonDraggableWindowView())
        }
    }

    // MARK: Pieces

    private func navigationRow(leadingInset: CGFloat) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: max(0, leadingInset - 8))
            navButtons
            if centeredAddressBar {
                Spacer(minLength: 8)
                address.frame(maxWidth: 640)
                Spacer(minLength: 8)
            } else {
                address.frame(maxWidth: .infinity)
            }
            toolbarIcons
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
    }

    private var navButtons: some View {
        HStack(spacing: 0) {
            ToolbarIconButton(systemName: "chevron.left", help: "Back (⌘[)", isEnabled: web.canGoBackForActiveTab) {
                if let id = store.activeTabId { web.goBack(in: id) }
            }
            ToolbarIconButton(systemName: "chevron.right", help: "Forward (⌘])", isEnabled: web.canGoForwardForActiveTab) {
                if let id = store.activeTabId { web.goForward(in: id) }
            }
            ToolbarIconButton(systemName: "arrow.clockwise", help: "Reload (⌘R)") {
                if let id = store.activeTabId { web.reload(in: id) }
            }
            if showHomeButton {
                ToolbarIconButton(systemName: "house", help: "Home", action: actions.goHome)
            }
        }
        .background(NonDraggableWindowView())
    }

    private var address: some View {
        TabRuntimeReader(state: web.tabRuntime.state(for: store.activeTabId)) { runtime in
            AddressField(
                url: activeURL,
                text: $addressText,
                focused: addressFocused,
                loadingProgress: runtime.loadingProgress,
                centered: centeredAddressBar,
                web: web,
                onSubmit: actions.submitAddress
            )
        }
    }

    private var tabStrip: some View {
        HorizontalTabStrip(
            store: store,
            web: web,
            onActivate: actions.activate,
            onClose: actions.close,
            onNewTab: actions.newTab,
            onSplit: actions.split,
            onTearOff: actions.tearOff,
            onMoveToNewWindow: actions.moveToNewWindow
        )
    }

    private var toolbarIcons: some View {
        HStack(spacing: 2) {
            ShieldsButton(web: web, extensions: extensions, tabId: store.activeTabId, url: activeURL)
            ToolbarIconButton(systemName: "sparkles", help: "Axolotl AI (⌘E)", action: actions.toggleAI)
            DownloadsButton()
            profileControl
            MoreMenu(actions: actions, extensions: extensions)
        }
        .background(NonDraggableWindowView())
    }
}

/// The "⋯" menu: tab, history, downloads and settings commands.
struct MoreMenu: View {
    let actions: TopChromeActions
    let extensions: ExtensionHost

    var body: some View {
        AxolotlMenuButton(alignment: .trailing, minWidth: 280, help: "More", debugID: "top.more", items: {
            AppMenuEntries.build(actions: actions, extensions: extensions,
                                 settings: AxolotlSettingsOpener())
        }) { isOpen in
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AxolotlSurface.hover.opacity(isOpen ? 1 : 0)))
                .contentShape(Rectangle())
        }
        .fixedSize()
        .background(PopupAnchor { extensions.menuAnchor = $0 })
    }
}

/// The omnibox star: filled blue when the page is bookmarked; click to add or remove it.
private struct ChromeStar: View {
    let url: URL?
    let bookmarks: BookmarkStore?
    let add: () -> Void

    var body: some View {
        if let bookmarks { Star(url: url, store: bookmarks, add: add) }
    }

    private struct Star: View {
        let url: URL?
        @ObservedObject var store: BookmarkStore
        let add: () -> Void
        @Environment(\.colorScheme) private var scheme
        @State private var isHovering = false

        var body: some View {
            let palette = ChromePalette.for(scheme)
            let saved = url.map(store.contains) ?? false
            Button {
                if saved, let url, let mark = store.bookmarks.first(where: { $0.url == url }) { store.remove(mark.id) } else { add() }
            } label: {
                Image(systemName: saved ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(saved ? palette.star : palette.icon)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(palette.hover.opacity(isHovering ? 1.5 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .disabled(url == nil)
            .help(saved ? "Remove Bookmark" : "Bookmark This Tab (⌘D)")
            .accessibilityLabel(saved ? "Remove Bookmark" : "Bookmark This Tab")
        }
    }
}

/// Chrome's extensions (puzzle piece) button.
private struct ChromeExtensionsButton: View {
    @ObservedObject var extensions: ExtensionHost
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Like Chrome, the puzzle piece shows once an extension is installed.
        let _ = extensions.actionRevision
        if !extensions.loaded.isEmpty { menu }
    }

    private var menu: some View {
        AxolotlMenuButton(alignment: .trailing, help: "Extensions", items: {
            let entries = ExtensionMenuEntries.build(host: extensions, settings: AxolotlSettingsOpener())
            if case .item(let item) = entries.first, let children = item.children { return children }
            return entries
        }) { isOpen in
            ChromeIcon(systemName: "puzzlepiece.extension", color: ChromePalette.for(scheme).icon)
                .frame(width: ChromeMetrics.toolbarButton, height: ChromeMetrics.toolbarButton)
                .background(Circle().fill(ChromePalette.for(scheme).hover.opacity(isOpen ? 1.5 : 0)))
                .contentShape(Circle())
        }
        .fixedSize()
    }
}

/// Chrome's vertical "⋮" menu, with Axolotl's commands.
private struct ChromeMenuButton: View {
    let actions: TopChromeActions
    let extensions: ExtensionHost
    @Environment(\.colorScheme) private var scheme


    var body: some View {
        AxolotlMenuButton(alignment: .trailing, minWidth: 320, debugID: "chrome.app", items: {
            AppMenuEntries.build(actions: actions, extensions: extensions,
                                 settings: AxolotlSettingsOpener())
        }) { isOpen in
            ChromeIcon(systemName: "ellipsis", color: ChromePalette.for(scheme).icon, rotation: .degrees(90))
                .frame(width: ChromeMetrics.toolbarButton, height: ChromeMetrics.toolbarButton)
                .background(Circle().fill(ChromePalette.for(scheme).hover.opacity(isOpen ? 1.5 : 0)))
                .contentShape(Circle())
        }
        .fixedSize()
        .background(PopupAnchor { extensions.menuAnchor = $0 })
        .help("Customize and control Axolotl")
        .accessibilityLabel("Customize and control Axolotl")
    }
}
