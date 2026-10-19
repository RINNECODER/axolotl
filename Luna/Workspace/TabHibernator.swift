import Combine
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
    private(set) var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var timeoutObserver: DefaultsObserver?

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

    /// Retry delay for a tab past its timeout that a sweep kept (playing media, using the camera).
    static let busyRecheck: TimeInterval = 60

    /// Watches tab activity and the timeout setting, and keeps one one-shot timer for the next
    /// tab due to unload (none when hibernation is off or no background tab is loaded).
    func start() {
        if subscriptions.isEmpty {
            // Debounced: `$workspace` sends before the change lands, and bursts of edits are common.
            store.$workspace
                .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.reschedule() }
                .store(in: &subscriptions)
            timeoutObserver = DefaultsObserver(keys: [Self.timeoutDefaultsKey]) { [weak self] in self?.reschedule() }
        }
        reschedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        subscriptions.removeAll()
        timeoutObserver = nil
    }

    /// When a loaded background tab next passes the timeout; nil when nothing can be unloaded.
    func nextSweepDate(now: Date = Date(), timeout: TimeInterval? = nil) -> Date? {
        let timeout = timeout ?? self.timeout
        guard timeout > 0 else { return nil }
        let visible = Set(store.visibleTabIds)
        return web.loadedTabIds.compactMap { id -> Date? in
            guard !visible.contains(id), let tab = store.tab(id) else { return nil }
            let due = tab.lastActiveAt.addingTimeInterval(timeout)
            return due > now ? due : now.addingTimeInterval(Self.busyRecheck)
        }.min()
    }

    private func reschedule() {
        guard let date = nextSweepDate() else {
            timer?.invalidate()
            timer = nil
            return
        }
        // An earlier pending timer stays: firing early only sweeps nothing and reschedules.
        if let timer, timer.isValid, timer.fireDate <= date.addingTimeInterval(1) { return }
        timer?.invalidate()
        let next = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep { [weak self] _ in self?.reschedule() } }
        }
        next.tolerance = 5
        RunLoop.main.add(next, forMode: .common)
        timer = next
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
