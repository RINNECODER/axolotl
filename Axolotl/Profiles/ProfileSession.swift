import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

/// Hands out one shared HistoryManager/ChatStore per profile so multiple windows
/// on the same profile write through a single instance instead of racing on the
/// same JSON files (last-write-wins data loss). Weak references keep the stores
/// alive only while at least one session uses them.
enum ProfileStoreRegistry {
    private struct WeakStores {
        weak var history: HistoryManager?
        weak var chats: ChatStore?
    }
    private static var cache: [UUID: WeakStores] = [:]

    static func stores(for profileId: UUID) -> (history: HistoryManager, chats: ChatStore) {
        var entry = cache[profileId] ?? WeakStores()
        let history = entry.history ?? HistoryManager(profileId: profileId)
        let chats = entry.chats ?? ChatStore(profileId: profileId)
        entry.history = history
        entry.chats = chats
        cache[profileId] = entry
        return (history, chats)
    }
}

/// Browser state owned by exactly one profile.
final class ProfileSession: ObservableObject {
    /// Every live session (all windows), for checks across windows such as Forget Me sites.
    private static let openSessions = NSHashTable<ProfileSession>.weakObjects()
    static func open(profileId: UUID) -> [ProfileSession] {
        openSessions.allObjects.filter { $0.profileId == profileId && !$0.isPrivate && !$0.isClosed }
    }

    /// Set once its window closed: its tabs no longer keep Forget Me sites alive.
    private(set) var isClosed = false

    private static func openHosts(_ profileId: UUID) -> [String] {
        open(profileId: profileId).flatMap { $0.workspace.workspace.tabs.values.compactMap(\.url?.host) }
    }

    /// Forget Me sites: once `session`'s change (its next workspace, or nil when its window closes) leaves a
    /// marked site without a tab in any window of the profile, clears that site's data.
    static func forgetSites(after session: ProfileSession, changesTo next: Workspace?) {
        guard !session.isPrivate, !session.isClosed else { return }
        let sites = ForgetSites.sites(session.profileId)
        guard !sites.isEmpty else { return }
        func hosts(_ ws: Workspace?) -> Set<String> { Set(ws?.tabs.values.compactMap(\.url?.host) ?? []) }
        guard next == nil || hosts(next) != hosts(session.workspace.workspace) else { return }
        let profileId = session.profileId, before = openHosts(profileId)
        guard !ForgetSites.sitesToForget(sites: sites, before: before, after: []).isEmpty else { return }
        // Checked a moment later, so a tab moving to another window counts as still open there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let after = openHosts(profileId)
            let gone = ForgetSites.sitesToForget(sites: ForgetSites.sites(profileId), before: before, after: after)
            ForgetSites.forget(gone, keeping: after, in: ProfileManager.shared.dataStore(for: profileId))
        }
    }

    /// Clears the marked sites of every profile that have no open tab: at launch, and (best effort) at quit.
    static func forgetClosedSites(atQuit: Bool) {
        var pending = 0
        for profile in ProfileManager.shared.profiles {
            let sites = ForgetSites.sites(profile.id)
            let open = atQuit ? [] : openHosts(profile.id)
            let gone = ForgetSites.sitesToForget(sites: sites, before: sites, after: open)
            guard !gone.isEmpty else { continue }
            pending += 1
            ForgetSites.forget(gone, keeping: open, in: ProfileManager.shared.dataStore(for: profile.id)) { pending -= 1 }
        }
        // Quitting: give WebKit up to 2 s to finish; next launch sweeps any marked site that has no restored tab.
        let deadline = Date().addingTimeInterval(2)
        while atQuit, pending > 0, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    /// Its window closed: clear Forget Me sites only it showed.
    func close() {
        Self.forgetSites(after: self, changesTo: nil)
        isClosed = true
    }

    let profileId: UUID
    let workspace: WorkspaceStore
    let tabManager: TabManager
    let webViewWrapper: WebViewWrapper
    let historyManager: HistoryManager
    let chatStore: ChatStore
    let hibernator: TabHibernator
    let extensions: ExtensionHost
    /// A private window's session: nothing it does is written to disk (see `PrivateBrowsing`).
    let isPrivate: Bool

    private var cancellables: Set<AnyCancellable> = []
    private var knownTabIds: Set<UUID> = []
    private var lastVisibleTabIds: [UUID] = []

    // Avoid the MainActor isolated-deinit executor hop that double-frees
    // task-local storage on current macOS runtimes (swiftlang/swift#88036).
    nonisolated deinit {}

    /// - Parameter workspace: injected store (tests); by default the profile's
    ///   persisted workspace when no other window owns it, else in-memory.
    ///   `isPrivate`: in-memory workspace, history and chats; pass a non-persistent `dataStore`.
    init(profileId: UUID, dataStore: WKWebsiteDataStore, workspace: WorkspaceStore? = nil, windowId: UUID? = nil,
         isPrivate: Bool = false) {
        self.profileId = profileId
        self.isPrivate = isPrivate
        self.workspace = workspace ?? (isPrivate ? WorkspaceStore(persistence: nil)
                                                 : WorkspaceOwnership.makeStore(for: profileId, windowId: windowId))
        self.tabManager = TabManager(store: self.workspace)
        if isPrivate {
            self.historyManager = HistoryManager(profileId: profileId, persistent: false)
            self.chatStore = ChatStore(profileId: profileId, persistent: false)
        } else {
            let stores = ProfileStoreRegistry.stores(for: profileId)
            self.historyManager = stores.history
            self.chatStore = stores.chats
        }
        self.webViewWrapper = WebViewWrapper(profileId: profileId, dataStore: dataStore)
        webViewWrapper.isPrivate = isPrivate
        self.hibernator = TabHibernator(store: self.workspace, web: webViewWrapper)
        self.extensions = ExtensionHost(profileId: profileId, dataStore: dataStore, isPrivate: isPrivate)
        webViewWrapper.extensionController = extensions.controller

        webViewWrapper.tabManager = tabManager
        let extensionHost = extensions
        webViewWrapper.onNavigationFinished = { [weak tabManager, weak historyManager, weak extensionHost] tabId, url, title in
            tabManager?.navigate(tab: tabId, to: url)
            tabManager?.updateTitle(tab: tabId, title: title)
            historyManager?.recordPageVisit(url: url, title: title)
            extensionHost?.tabChanged(tabId, [.URL, .title, .loading])
        }
        webViewWrapper.onTabNavigationBecameDownload = { [weak self] tabId, committedURL, isPopup in
            guard let self else { return }
            if let committedURL {
                // The tab still shows its page; keep that, not the download URL.
                self.workspace.updateURL(tabId, committedURL)
            } else if isPopup, self.workspace.orderedTabIds.count > 1 {
                // A link opened a tab just to download: close it, like Safari and Chrome.
                if self.workspace.close(tabId) == .removed { self.webViewWrapper.removeWebView(for: tabId) }
            } else {
                self.workspace.updateURL(tabId, nil)
            }
        }
        Self.openSessions.add(self)
        self.workspace.captureInteractionStates = { [weak webViewWrapper] in
            webViewWrapper?.interactionStates() ?? [:]
        }
        self.workspace.onTabPinned = { [weak self] id in
            Usage.record(.pinTab)
            if self?.isPrivate == false, AxolotlMaxPrefs.isOn(AxolotlMaxPrefs.tidyTitles) { self?.tidyTitle(id, reportErrors: false) }
        }

        // History and chats aren't forwarded: the views showing them observe them directly.
        tabManager.objectWillChange
            .merge(with: webViewWrapper.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Restore: guarantee an active tab, then lazily load it.
        let store = self.workspace
        if store.orderedTabIds.isEmpty {
            _ = store.newTab(url: nil)
        } else if store.activeTabId == nil, let first = store.orderedTabIds.first {
            store.activate(first)
        }
        knownTabIds = Set(store.workspace.tabs.keys)
        lastVisibleTabIds = store.visibleTabIds

        // Switching to an existing tab that has no web view (restored, reset
        // pinned tab, hibernated) loads it. Brand-new tabs are loaded by whoever
        // created them, so they're skipped here.
        store.$workspace
            .sink { [weak self] ws in self?.workspaceWillChange(to: ws) }
            .store(in: &cancellables)

        if let tabId = store.activeTabId {
            webViewWrapper.setActiveTab(tabId)
            // Deferred so the restored page(s) load after the window has rendered.
            let visible = store.visibleTabIds
            DispatchQueue.main.async { [weak self] in visible.forEach { self?.ensureLoaded($0) } }
        }
        hibernator.start()
        extensions.attach(self)
    }

    func activate() {
        guard let tabId = workspace.activeTabId else { return }
        webViewWrapper.setActiveTab(tabId)
        workspace.visibleTabIds.forEach(ensureLoaded)
        hibernator.start()
    }

    /// Creates and loads (or restores) the tab's web view if it has none.
    func ensureLoaded(_ tabId: UUID) {
        // The shell may already have created an empty web view while rendering.
        if let wv = webViewWrapper.webViewIfLoaded(for: tabId), wv.url != nil || wv.isLoading { return }
        guard let tab = workspace.tab(tabId),
              let url = tab.url,
              url.absoluteString != "about:blank",
              !InternalPage.isInternal(url) else { return }
        if let state = tab.interactionState {
            webViewWrapper.restore(interactionState: state, fallbackURL: url, in: tabId)
            workspace.clearInteractionState(tabId)
        } else {
            webViewWrapper.load(url: url, in: tabId)
        }
    }

    // MARK: - Axolotl Max

    /// Replaces the tab's title with a short AI-chosen one.
    func tidyTitle(_ id: UUID, reportErrors: Bool = true) {
        guard let tab = workspace.tab(id) else { return }
        let source = tab.title.isEmpty ? (tab.url?.host ?? "") : tab.title
        guard !source.isEmpty else { return }
        Task {
            do {
                let title = try await AxolotlMax.tidyTitle(for: source, url: tab.url)
                workspace.setCustomTitle(id, title)
            } catch {
                if reportErrors { Self.showError(error, title: "Couldn't tidy the title") }
            }
        }
    }

    /// Groups the active space's loose Today tabs into folders.
    func tidyToday() {
        Usage.record(.tidyToday)
        let space = workspace.activeSpace
        let tabs: [AxolotlMax.TabSummary] = space.today.compactMap { node in
            guard case .tab(let id) = node, let tab = workspace.tab(id) else { return nil }
            return AxolotlMax.TabSummary(id: id, title: displayTitle(for: tab), host: tab.url?.host ?? "")
        }
        guard tabs.count >= 3 else { return }
        Task {
            do {
                let groups = try await AxolotlMax.tidyGroups(for: tabs)
                if groups.isEmpty { NSSound.beep() } else { workspace.applyTidyGroups(groups, inSpace: space.id) }
            } catch {
                Self.showError(error, title: "Couldn't tidy tabs")
            }
        }
    }

    static func showError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func suspend() {
        hibernator.stop()
        workspace.flush()
        historyManager.flush()
        chatStore.flush()
        webViewWrapper.removeAllWebViews()
        WorkspaceOwnership.release(workspace, profileId: profileId)
    }

    private func workspaceWillChange(to ws: Workspace) {
        Self.forgetSites(after: self, changesTo: ws)
        let visible = ws.visibleTabIds
        let previouslyKnown = knownTabIds
        knownTabIds = Set(ws.tabs.keys)
        // Keep extensions' view of tabs current.
        let previousActive = workspace.activeTabId
        let opened = knownTabIds.subtracting(previouslyKnown)
        let closed = previouslyKnown.subtracting(knownTabIds)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            opened.forEach(self.extensions.tabOpened)
            closed.forEach(self.extensions.tabClosed)
            if let active = ws.activeTabId, active != previousActive {
                self.extensions.tabActivated(active, previous: previousActive)
            }
        }
        guard visible != lastVisibleTabIds else { return }
        lastVisibleTabIds = visible
        let toLoad = visible.filter { previouslyKnown.contains($0) }
        guard !toLoad.isEmpty else { return }
        // `$workspace` fires before the value is stored; load once it's committed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            toLoad.filter { self.workspace.visibleTabIds.contains($0) }.forEach(self.ensureLoaded)
        }
    }
}

/// Owns the per-profile sessions used by a single browser window.
final class BrowserSessionStore: ObservableObject {
    @Published private(set) var activeProfileId: UUID
    @Published private(set) var activeSession: ProfileSession

    private let profileManager: ProfileManager
    private var sessions: [UUID: ProfileSession] = [:]
    private var suspensionTasks: [UUID: DispatchWorkItem] = [:]
    private var activeSessionSubscription: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?
    /// A private window: one ephemeral session that never switches profile.
    let isPrivate: Bool

    /// - Parameter windowId: set for extra windows, which save their own workspace.
    init(initialProfileId: UUID? = nil, windowId: UUID? = nil, isPrivate: Bool = false, profileManager: ProfileManager = .shared) {
        self.profileManager = profileManager
        self.isPrivate = isPrivate
        let id = profileManager.validProfileId(initialProfileId ?? profileManager.lastActiveProfileId)
        let session = isPrivate
            ? ProfileSession(profileId: id, dataStore: PrivateBrowsing.dataStore(), isPrivate: true)
            : ProfileSession(profileId: id, dataStore: profileManager.dataStore(for: id), windowId: windowId)
        self.activeProfileId = id
        self.activeSession = session
        self.sessions[id] = session
        subscribeToActiveSession()
        // Persist history/chats even when the app quits without the view disappearing first.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.flush()
        }
    }

    // nonisolated to avoid the MainActor isolated-deinit executor hop
    // (swiftlang/swift#88036); NotificationCenter removal is thread-safe.
    nonisolated deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func switchTo(profileId: UUID) {
        let id = profileManager.validProfileId(profileId)
        guard id != activeProfileId, !isPrivate else { return }

        let outgoingId = activeProfileId
        scheduleSuspension(for: outgoingId)
        suspensionTasks[id]?.cancel()
        suspensionTasks.removeValue(forKey: id)

        let session = sessions[id] ?? ProfileSession(
            profileId: id,
            dataStore: profileManager.dataStore(for: id)
        )
        sessions[id] = session
        activeProfileId = id
        activeSession = session
        profileManager.markLastActive(profileId: id)
        subscribeToActiveSession()
        session.activate()
    }

    /// This window closed: its tabs stop keeping Forget Me sites alive.
    func closeAll() { sessions.values.forEach { $0.close() } }

    func removeSession(profileId: UUID) {
        suspensionTasks[profileId]?.cancel()
        suspensionTasks.removeValue(forKey: profileId)
        sessions.removeValue(forKey: profileId)?.suspend()
    }

    /// Tears down sessions whose profiles no longer exist (e.g. deleted while inactive).
    func pruneSessions(keeping validProfileIds: Set<UUID>) {
        for id in sessions.keys where !validProfileIds.contains(id) && id != activeProfileId {
            removeSession(profileId: id)
        }
    }

    func flush() {
        sessions.values.forEach {
            $0.workspace.flush()
            $0.historyManager.flush()
            $0.chatStore.flush()
        }
    }

    private func subscribeToActiveSession() {
        activeSessionSubscription = activeSession.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func scheduleSuspension(for profileId: UUID) {
        suspensionTasks[profileId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activeProfileId != profileId else { return }
            // Suspend and release: keeping suspended sessions in the map would
            // retain their TabManager/WebViewWrapper/stores for the window's lifetime.
            self.sessions.removeValue(forKey: profileId)?.suspend()
            self.suspensionTasks.removeValue(forKey: profileId)
        }
        suspensionTasks[profileId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }
}
