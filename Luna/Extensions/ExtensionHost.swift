import AppKit
import Combine
import WebKit

/// One profile's web-extension runtime: a WKWebExtensionController holding a
/// context per enabled extension, and adapters that expose Luna's tabs and
/// window to extensions (tabs, windows, actions, popups, permissions).
final class ExtensionHost: NSObject, ObservableObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController
    private weak var session: ProfileSession?
    private var contexts: [UUID: WKWebExtensionContext] = [:]
    private var tabAdapters: [UUID: ExtensionTabAdapter] = [:]
    private(set) lazy var window = ExtensionWindowAdapter(host: self)
    private var cancellables: Set<AnyCancellable> = []
    /// Toolbar buttons register their views so popups can anchor to them.
    var popupAnchors: [UUID: NSView] = [:]
    /// The ⋯ menu button: popups for actions run from the menu open here.
    weak var menuAnchor: NSView?
    /// Bumped when an extension's action (icon, badge, title) changes.
    @Published private(set) var actionRevision = 0
    /// The bundled uBlock Origin Lite, which Shields drives.
    private var ubol: (context: WKWebExtensionContext, bridge: UBOLBridge)?
    private var shieldsDefault = ShieldsPrefs.defaults().level
    private var shieldsLevelObserver: DefaultsObserver?

    nonisolated deinit {}

    init(profileId: UUID, dataStore: WKWebsiteDataStore, isPrivate: Bool = false) {
        // Private windows: extension storage lives in memory, apart from the profile's.
        let config = isPrivate ? WKWebExtensionController.Configuration.nonPersistent()
                               : WKWebExtensionController.Configuration(identifier: profileId)
        config.defaultWebsiteDataStore = dataStore
        controller = WKWebExtensionController(configuration: config)
        super.init()
        controller.delegate = self
        ExtensionLibrary.shared.$records
            .sink { [weak self] records in
                DispatchQueue.main.async { self?.sync(with: records) }
            }
            .store(in: &cancellables)
        // Settings' Shields level is uBOL's default mode; changing it clears uBOL's per-site modes at that level.
        shieldsLevelObserver = DefaultsObserver(keys: [ShieldsPrefs.level]) { [weak self] in
            let level = UserDefaults.standard.string(forKey: ShieldsPrefs.level).flatMap(ShieldsLevel.init(rawValue:)) ?? .standard
            guard let self, level != self.shieldsDefault else { return }
            self.pushShields()
        }
    }

    func attach(_ session: ProfileSession) {
        self.session = session
        // Site exceptions edited anywhere (panel, Site Settings) reach uBOL; `$sites` sends the new value.
        var previous = session.webViewWrapper.shields.sites
        session.webViewWrapper.shields.$sites
            .sink { [weak self] sites in
                let changed = Set(previous.keys).union(sites.keys).filter { previous[$0] != sites[$0] }
                previous = sites
                DispatchQueue.main.async { for host in changed { Task { await self?.applyShields(host: host) } } }
            }
            .store(in: &cancellables)
        sync(with: ExtensionLibrary.shared.records)
    }

    // MARK: Loading

    /// Loads enabled extensions and unloads removed/disabled ones.
    private func sync(with records: [ExtensionLibrary.Record]) {
        let wanted = Set(records.filter(\.enabled).map(\.id))
        for (id, context) in contexts where !wanted.contains(id) {
            try? controller.unload(context)
            contexts.removeValue(forKey: id)
            if ubol?.context === context { ubol = nil }
        }
        for record in records where record.enabled && contexts[record.id] == nil {
            let dir = ExtensionLibrary.shared.directory(for: record)
            Task {
                guard let ext = try? await WKWebExtension(resourceBaseURL: dir), contexts[record.id] == nil else { return }
                let context = WKWebExtensionContext(for: ext)
                // Stable identity keeps the extension's storage across launches.
                context.uniqueIdentifier = record.id.uuidString
                // The user approved these when installing.
                for permission in ext.requestedPermissions {
                    context.setPermissionStatus(.grantedExplicitly, for: permission)
                }
                for pattern in ext.allRequestedMatchPatterns {
                    context.setPermissionStatus(.grantedExplicitly, for: pattern)
                }
                #if DEBUG
                context.isInspectable = true
                #endif
                do {
                    try controller.load(context)
                    contexts[record.id] = context
                    if record.builtInID == "ubolite" {
                        ubol = (context, UBOLBridge(context: context))
                        pushShields()
                    }
                    actionRevision += 1
                    #if DEBUG
                    if !context.errors.isEmpty { NSLog("ExtensionHost: %@ loaded with errors: %@", record.name, "\(context.errors)") }
                    #endif
                } catch {
                    print("ExtensionHost: failed to load \(record.name): \(error)")
                }
            }
        }
        actionRevision += 1
    }

    /// Loaded extensions with their records, in install order.
    var loaded: [(record: ExtensionLibrary.Record, context: WKWebExtensionContext)] {
        ExtensionLibrary.shared.records.compactMap { r in contexts[r.id].map { (r, $0) } }
    }

    // MARK: Tabs

    func adapter(for tabId: UUID) -> ExtensionTabAdapter {
        if let existing = tabAdapters[tabId] { return existing }
        let adapter = ExtensionTabAdapter(tabId: tabId, host: self)
        tabAdapters[tabId] = adapter
        return adapter
    }

    var store: WorkspaceStore? { session?.workspace }
    var web: WebViewWrapper? { session?.webViewWrapper }

    var activeTabAdapter: ExtensionTabAdapter? {
        store?.activeTabId.map(adapter(for:))
    }

    func tabOpened(_ id: UUID) { controller.didOpenTab(adapter(for: id)) }

    func tabClosed(_ id: UUID) {
        web?.shieldsCounter.tabClosed(id)
        guard let adapter = tabAdapters.removeValue(forKey: id) else { return }
        controller.didCloseTab(adapter, windowIsClosing: false)
    }

    func tabActivated(_ id: UUID, previous: UUID?) {
        controller.didActivateTab(adapter(for: id), previousActiveTab: previous.map(adapter(for:)))
    }

    func tabChanged(_ id: UUID, _ properties: WKWebExtension.TabChangedProperties) {
        controller.didChangeTabProperties(properties, for: adapter(for: id))
    }

    /// Opens a tab for an extension (new tab, options page).
    func openTab(url: URL?, activate: Bool) -> ExtensionTabAdapter? {
        guard let session else { return nil }
        let id = session.workspace.newTab(url: url, activate: activate)
        if let url, url.scheme != "about" {
            session.webViewWrapper.load(url: url, in: id)
        }
        if activate { session.webViewWrapper.setActiveTab(id) }
        return adapter(for: id)
    }

    func closeTab(_ id: UUID) {
        guard let session else { return }
        session.webViewWrapper.removeWebView(for: id)
        session.chatStore.removeMessages(for: id)
        session.workspace.close(id)
    }

    // MARK: Shields

    /// uBOL's blocked count for a tab (its action badge), 0 when uBOL is off or shows no count.
    func blockedCount(for tabId: UUID) -> Int {
        guard let ubol else { return 0 }
        return Int(ubol.context.action(for: adapter(for: tabId))?.badgeText ?? "") ?? 0
    }

    var hasAdBlocker: Bool { ubol != nil }

    /// Sends one site's Shields level to uBOL.
    func applyShields(host: String) async {
        guard let ubol, let shields = web?.shields else { return }
        let mode = shields.policy(host: host).effectiveLevel.uBOLMode
        await ubol.bridge.send(["what": "setFilteringMode", "hostname": host, "level": mode])
    }

    /// The default level, then every site with its own Shields settings (private sessions start empty).
    private func pushShields() {
        guard let ubol, let shields = web?.shields else { return }
        shieldsDefault = ShieldsPrefs.defaults().level
        let modes = shields.sites.keys.map { ($0, shields.policy(host: $0).effectiveLevel.uBOLMode) }
        let level = shieldsDefault.uBOLMode
        Task {
            await ubol.bridge.send(["what": "setDefaultFilteringMode", "level": level])
            for (host, mode) in modes {
                await ubol.bridge.send(["what": "setFilteringMode", "hostname": host, "level": mode])
            }
        }
    }

    // MARK: Actions

    func performAction(_ context: WKWebExtensionContext) {
        context.performAction(for: activeTabAdapter)
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        completionHandler(openTab(url: configuration.url, activate: configuration.shouldBeActive), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        // Luna has one window per profile session; open the URLs as tabs in it.
        for url in configuration.tabURLs { _ = openTab(url: url, activate: true) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        _ = openTab(url: extensionContext.optionsPageURL, activate: true)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        let allowed = Self.ask("“\(extensionContext.webExtension.displayName ?? "An extension")” wants more permissions",
                               detail: names)
        completionHandler(allowed ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = Set(urls.compactMap(\.host)).sorted().joined(separator: ", ")
        let allowed = Self.ask("Allow “\(extensionContext.webExtension.displayName ?? "An extension")” on \(hosts)?",
                               detail: "It will be able to read and change content on these sites.")
        completionHandler(allowed ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let list = matchPatterns.map(\.string).sorted().joined(separator: ", ")
        let allowed = Self.ask("Allow “\(extensionContext.webExtension.displayName ?? "An extension")” access to more sites?",
                               detail: list)
        completionHandler(allowed ? matchPatterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        if context === ubol?.context, let tab = action.associatedTab as? ExtensionTabAdapter {
            web?.shieldsCounter.observe(tab: tab.tabId, count: Int(action.badgeText) ?? 0)
        }
        actionRevision += 1
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else { return completionHandler(nil) }
        let recordId = contexts.first { $0.value === context }?.key
        if let id = recordId, let anchor = popupAnchors[id], anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let anchor = menuAnchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let contentView = NSApp.keyWindow?.contentView {
            let rect = NSRect(x: contentView.bounds.maxX - 60, y: contentView.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
        completionHandler(nil)
    }

    private static func ask(_ title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Adapters

/// A Luna tab as seen by extensions.
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    let tabId: UUID
    private weak var host: ExtensionHost?

    nonisolated deinit {}

    init(tabId: UUID, host: ExtensionHost) {
        self.tabId = tabId
        self.host = host
    }

    private var tab: Tab? { host?.store?.tab(tabId) }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { host?.window }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        host?.store?.orderedTabIds.firstIndex(of: tabId) ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { host?.web?.webViewIfLoaded(for: tabId) }

    func title(for context: WKWebExtensionContext) -> String? { tab.map(displayTitle(for:)) }

    func url(for context: WKWebExtensionContext) -> URL? {
        host?.web?.webViewIfLoaded(for: tabId)?.url ?? tab?.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(host?.web?.webViewIfLoaded(for: tabId)?.isLoading ?? false)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool { host?.store?.activeTabId == tabId }

    func isPinned(for context: WKWebExtensionContext) -> Bool { host?.store?.workspace.isPersistent(tabId) ?? false }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if pinned { host?.store?.pin(tabId) } else { host?.store?.unpin(tabId) }
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host?.store?.activate(tabId)
        host?.web?.setActiveTab(tabId)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host?.store?.updateURL(tabId, url)
        host?.web?.load(url: url, in: tabId)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host?.web?.reload(in: tabId)
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host?.web?.goBack(in: tabId)
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host?.web?.goForward(in: tabId)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        host?.closeTab(tabId)
        completionHandler(nil)
    }

    /// Clicking the extension's button grants `activeTab` for that tab.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

/// The profile window as seen by extensions.
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    private weak var host: ExtensionHost?

    nonisolated deinit {}

    init(host: ExtensionHost) {
        self.host = host
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let host else { return [] }
        return (host.store?.orderedTabIds ?? []).map(host.adapter(for:))
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { host?.activeTabAdapter }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    private var nsWindow: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .zero }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? .zero }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        nsWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}
