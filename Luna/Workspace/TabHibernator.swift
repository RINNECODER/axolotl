import Foundation

/// Unloads web views for tabs that haven't been looked at for a while, keeping
/// their back/forward state in the workspace so they restore on activation.
/// Visible tabs and tabs playing media or using camera/mic are never unloaded.
final class TabHibernator {
    /// Minutes of inactivity before a background tab is unloaded; 0 disables.
    static let timeoutDefaultsKey = "luna_tab_hibernate_minutes"
    static let defaultTimeoutMinutes = 30

    private let store: WorkspaceStore
    private let web: WebViewWrapper
    private var timer: Timer?

    nonisolated deinit {}

    init(store: WorkspaceStore, web: WebViewWrapper) {
        self.store = store
        self.web = web
    }

    var timeout: TimeInterval {
        let defaults = UserDefaults.standard
        let minutes = defaults.object(forKey: Self.timeoutDefaultsKey) == nil
            ? Self.defaultTimeoutMinutes
            : defaults.integer(forKey: Self.timeoutDefaultsKey)
        return TimeInterval(max(0, minutes)) * 60
    }

    func start(interval: TimeInterval = 60) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Tabs eligible for unloading before the async media/capture check.
    func candidates(now: Date = Date(), timeout: TimeInterval) -> [UUID] {
        guard timeout > 0 else { return [] }
        let visible = Set(store.visibleTabIds)
        return web.loadedTabIds.filter { id in
            guard !visible.contains(id), let tab = store.tab(id) else { return false }
            return now.timeIntervalSince(tab.lastActiveAt) > timeout
        }
    }

    /// Unloads idle tabs. `completion` receives the ids that were unloaded.
    func sweep(now: Date = Date(), timeout: TimeInterval? = nil, completion: (([UUID]) -> Void)? = nil) {
        let ids = candidates(now: now, timeout: timeout ?? self.timeout)
        guard !ids.isEmpty else {
            completion?([])
            return
        }
        var unloaded: [UUID] = []
        var remaining = ids.count
        for id in ids {
            web.isBusy(id) { [weak self] busy in
                guard let self else { return }
                // Re-check: the tab may have become visible while we waited.
                if !busy, !self.store.visibleTabIds.contains(id), self.web.loadedTabIds.contains(id) {
                    self.unload(id)
                    unloaded.append(id)
                }
                remaining -= 1
                if remaining == 0 { completion?(unloaded) }
            }
        }
    }

    private func unload(_ id: UUID) {
        store.setInteractionState(id, web.interactionState(of: id))
        web.removeWebView(for: id, keepMetadata: true)
    }
}
