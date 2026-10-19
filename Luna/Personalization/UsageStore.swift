import Combine
import Foundation

/// Settings → Personalization. Off by default: nothing is recorded until the user turns it on.
enum PersonalizationPrefs {
    static let enabledKey = "luna_personalization_enabled"
    static let retentionKey = "luna_personalization_retention_days"
    static let retentionChoices = [30, 90, 365]
    static let defaultRetention = 90
    /// What the read tools say when the record is off.
    static let offMessage = "Personalization is off. The user can turn it on in Luna → Settings → Personalization."

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }

    static func retentionDays(_ defaults: UserDefaults = .standard) -> Int {
        let days = defaults.integer(forKey: retentionKey)
        return retentionChoices.contains(days) ? days : defaultRetention
    }
}

/// Browser features whose use is counted (per day) while personalization is on.
enum UsageFeature: String, CaseIterable, Codable {
    case newTab = "tab.new"
    case closeTab = "tab.close"
    case reopenTab = "tab.reopen"
    case switchTab = "tab.switch"
    case pinTab = "tab.pin"
    case newWindow = "window.new"
    case splitView = "split.open"
    case find = "find"
    case askOnPage = "ask_on_page"
    case downloads = "downloads"
    case history = "history"
    case addressBar = "address_bar"
    case toggleSidebar = "sidebar.toggle"
    case reload = "reload"
    case zoom = "zoom"
    case print = "print"
    case bookmarkOpen = "bookmark.open"
    case bookmarkAdd = "bookmark.add"
    case tidyToday = "tidy_today"
    case aiPanel = "ai.panel"
    case aiChat = "ai.chat"
    case aiAgent = "ai.agent"
    case aiGrabKey = "ai.grab_key"
    case aiPersonalize = "ai.personalize"

    var title: String {
        switch self {
        case .newTab: return "New tab"
        case .closeTab: return "Close tab"
        case .reopenTab: return "Reopen closed tab"
        case .switchTab: return "Switch tab"
        case .pinTab: return "Pin tab"
        case .newWindow: return "New window"
        case .splitView: return "Split view"
        case .find: return "Find in page"
        case .askOnPage: return "Ask on Page"
        case .downloads: return "Downloads"
        case .history: return "History"
        case .addressBar: return "Address bar"
        case .toggleSidebar: return "Show/hide sidebar"
        case .reload: return "Reload"
        case .zoom: return "Zoom"
        case .print: return "Print"
        case .bookmarkOpen: return "Open bookmark"
        case .bookmarkAdd: return "Add bookmark"
        case .tidyToday: return "Tidy Today"
        case .aiPanel: return "AI panel"
        case .aiChat: return "AI chat"
        case .aiAgent: return "AI agent task"
        case .aiGrabKey: return "Grab API key"
        case .aiPersonalize: return "Personalize"
        }
    }
}

/// One day of counts. Hours are local (0–23).
struct UsageDay: Codable, Equatable {
    var features: [String: Int] = [:]
    var shortcuts: [String: Int] = [:]
    var hours: [Int] = Array(repeating: 0, count: 24)
    var maxOpenTabs = 0
}

/// The opt-in usage record of one profile: feature and shortcut counts in daily buckets,
/// stored next to the profile's history (Application Support/Luna/Profiles/<id>/usage.json).
/// Site visits are not duplicated here; they come from `HistoryManager`.
final class UsageStore: ObservableObject {
    @Published private(set) var days: [String: UsageDay] = [:]

    let fileURL: URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private var pendingSave: DispatchWorkItem?

    nonisolated deinit {}

    init(fileURL: URL, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.now = now
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: UsageDay].self, from: data) {
            days = saved
        }
        prune()
    }

    // MARK: Per-profile instances

    private static var stores: [UUID: UsageStore] = [:]

    static func forProfile(_ id: UUID) -> UsageStore {
        if let store = stores[id] { return store }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luna/Profiles/\(id.uuidString)", isDirectory: true)
        let store = UsageStore(fileURL: dir.appendingPathComponent("usage.json"))
        stores[id] = store
        return store
    }

    /// Drops a deleted profile's record and its pending save.
    static func forget(_ id: UUID) { stores.removeValue(forKey: id)?.deleteAll() }

    // MARK: Recording

    var isEnabled: Bool { PersonalizationPrefs.isEnabled(defaults) }

    func record(_ feature: UsageFeature) {
        mutateToday { $0.features[feature.rawValue, default: 0] += 1 }
    }

    /// A keyboard shortcut, e.g. "⌘T".
    func recordShortcut(_ shortcut: String) {
        mutateToday { $0.shortcuts[shortcut, default: 0] += 1 }
    }

    func noteOpenTabs(_ count: Int) {
        guard isEnabled, count > (days[Self.dayKey(now())]?.maxOpenTabs ?? 0) else { return }
        mutateToday(countsAsActivity: false) { $0.maxOpenTabs = count }
    }

    private func mutateToday(countsAsActivity: Bool = true, _ change: (inout UsageDay) -> Void) {
        guard isEnabled else { return }
        let date = now()
        let key = Self.dayKey(date)
        var day = days[key] ?? UsageDay()
        change(&day)
        if countsAsActivity { day.hours[Calendar.current.component(.hour, from: date)] += 1 }
        if days[key] == nil { pruneLocked(&days) }
        days[key] = day
        scheduleSave()
    }

    // MARK: Retention

    /// Drops days older than the retention window.
    func prune() {
        var copy = days
        pruneLocked(&copy)
        if copy != days {
            days = copy
            scheduleSave()
        }
    }

    private func pruneLocked(_ days: inout [String: UsageDay]) {
        let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -(PersonalizationPrefs.retentionDays(defaults) - 1),
                                                       to: now()) ?? now())
        days = days.filter { $0.key >= cutoff }
    }

    func deleteAll() {
        pendingSave?.cancel()
        days = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Reading

    /// Days within the last `days` days (today included).
    func buckets(days count: Int) -> [UsageDay] {
        let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -(max(1, count) - 1), to: now()) ?? now())
        return days.filter { $0.key >= cutoff }.map(\.value)
    }

    func featureTotals(days count: Int) -> [(feature: UsageFeature, count: Int)] {
        var totals: [String: Int] = [:]
        for day in buckets(days: count) { day.features.forEach { totals[$0.key, default: 0] += $0.value } }
        return totals.compactMap { k, v in UsageFeature(rawValue: k).map { ($0, v) } }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.feature.rawValue < $1.feature.rawValue }
    }

    func shortcutTotals(days count: Int) -> [(shortcut: String, count: Int)] {
        var totals: [String: Int] = [:]
        for day in buckets(days: count) { day.shortcuts.forEach { totals[$0.key, default: 0] += $0.value } }
        return totals.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.shortcut < $1.shortcut }
    }

    func activeHours(days count: Int) -> [Int] {
        var hours = Array(repeating: 0, count: 24)
        for day in buckets(days: count) { for h in 0..<24 where h < day.hours.count { hours[h] += day.hours[h] } }
        return hours
    }

    var isEmpty: Bool { days.isEmpty }

    // MARK: Storage

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard isEnabled || !days.isEmpty else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// App-wide entry point for recording: counts go to the active profile's record, and
/// only while personalization is on.
enum Usage {
    static var profileId: () -> UUID = { ProfileManager.shared.lastActiveProfileId }

    /// Cached copy of the personalization flag, kept current by KVO so recording
    /// while it is off doesn't read UserDefaults on every call.
    private final class EnabledFlag: NSObject {
        private let lock = NSLock()
        private var value: Bool

        override init() {
            value = PersonalizationPrefs.isEnabled()
            super.init()
            UserDefaults.standard.addObserver(self, forKeyPath: PersonalizationPrefs.enabledKey, options: [], context: nil)
        }

        var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return value }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            let fresh = PersonalizationPrefs.isEnabled()
            lock.lock(); value = fresh; lock.unlock()
        }
    }
    private static let enabledFlag = EnabledFlag()
    /// Set while a private window is key: nothing it does is recorded.
    static var paused = false
    private static var isEnabled: Bool { enabledFlag.isEnabled && !paused }

    static func record(_ feature: UsageFeature) {
        guard isEnabled else { return }
        UsageStore.forProfile(profileId()).record(feature)
    }

    static func recordShortcut(_ shortcut: String) {
        guard isEnabled else { return }
        UsageStore.forProfile(profileId()).recordShortcut(shortcut)
    }

    static func noteOpenTabs(_ count: Int) {
        guard isEnabled else { return }
        UsageStore.forProfile(profileId()).noteOpenTabs(count)
    }
}
