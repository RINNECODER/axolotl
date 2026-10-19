// Luma MVP - History Management System
import Foundation
import Combine

/// Browsing history and chat conversation summaries for one profile.
/// Visits live in SQLite (`HistoryStore`); every store call runs on `ioQueue`, never the main thread.
/// `historyEvents` is only the newest `recentWindow` visits kept in memory for personalization;
/// the history page and address bar query the store asynchronously.
final class HistoryManager: ObservableObject {
    @Published private(set) var historyEvents: [HistoryEvent] = []
    @Published private(set) var conversationSummaries: [UUID: [ConversationSummary]] = [:] // tabId -> summaries
    
    private let fileManager = FileManager.default
    private let profileId: UUID
    private let legacyHistoryFileName = "browsing_history.json"
    private let summariesFileName = "conversation_summaries.json"
    private let recentWindow = 10_000
    private var recordsSinceExpiry = 0
    private var pendingSummariesSave: DispatchWorkItem?
    /// Serial queue for disk writes so JSON encoding never blocks the main thread.
    private let saveQueue = DispatchQueue(label: "com.luna.history-save", qos: .utility)
    /// Serial queue owning `store`.
    nonisolated private let ioQueue = DispatchQueue(label: "com.luna.history-db", qos: .utility)
    nonisolated private let store: HistoryStore

    private var profileDir: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Luna/Profiles/\(profileId.uuidString)", isDirectory: true)
    }
    
    private var summariesFileURL: URL {
        let lumaDir = profileDir
        try? fileManager.createDirectory(at: lumaDir, withIntermediateDirectories: true)
        return lumaDir.appendingPathComponent(summariesFileName)
    }
    
    /// false (private windows): records no visits and writes nothing; summaries stay in memory.
    let persistent: Bool

    init(profileId: UUID, persistent: Bool = true) {
        self.profileId = profileId
        self.persistent = persistent
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Luna/Profiles/\(profileId.uuidString)", isDirectory: true)
        store = HistoryStore(fileURL: persistent ? dir.appendingPathComponent("history.sqlite") : nil)
        guard persistent else { return }
        loadHistory(legacyJSON: dir.appendingPathComponent(legacyHistoryFileName))
        loadSummaries()
    }

    // Avoid the MainActor isolated-deinit executor hop that double-frees
    // task-local storage on current macOS runtimes (swiftlang/swift#88036).
    nonisolated deinit {}

    private static func event(_ r: HistoryStore.Row) -> HistoryEvent {
        HistoryEvent(id: r.id, timestamp: r.date, type: .pageVisit, url: r.url, pageTitle: r.title)
    }

    /// Runs `work` on the store queue and hands its result back on the main actor.
    private func query<T: Sendable>(_ work: @escaping @Sendable (HistoryStore) -> T) async -> T {
        let store = store
        return await withCheckedContinuation { cont in ioQueue.async { cont.resume(returning: work(store)) } }
    }
    
    // MARK: - Page Visit Tracking
    
    func recordPageVisit(url: URL, title: String) {
        guard persistent, url.scheme == "http" || url.scheme == "https" || url.scheme == "file" else { return }
        // Pages control both: keep a hostile title or URL from bloating the history file.
        let urlString = String(url.absoluteString.prefix(2000))
        let title = String(title.prefix(300))
        if let latest = historyEvents.first,
           latest.type == .pageVisit,
           latest.url == urlString,
           Date().timeIntervalSince(latest.timestamp) < 2 {
            return
        }
        let event = HistoryEvent(
            timestamp: Date(),
            type: .pageVisit,
            url: urlString,
            pageTitle: title
        )
        historyEvents.insert(event, at: 0)
        if historyEvents.count > recentWindow {
            historyEvents.removeLast(historyEvents.count - recentWindow)
        }
        let row = HistoryStore.Row(id: event.id, date: event.timestamp, url: urlString, title: title)
        recordsSinceExpiry += 1
        let expire = recordsSinceExpiry >= 1_000
        if expire { recordsSinceExpiry = 0 }
        let store = store
        ioQueue.async {
            store.insert([row])
            if expire { store.expire() }
        }
    }
    
    /// Adds visits imported from another browser. Skips visits already present
    /// (same URL within the same second). Blocks the calling thread for the write,
    /// so importers call it from a background thread, one batch at a time.
    /// Returns how many were added.
    @discardableResult
    nonisolated func importVisits(_ visits: [ImportedVisit]) -> Int {
        let rows = visits.map { HistoryStore.Row(id: UUID(), date: $0.date, url: $0.url, title: $0.title) }
        let store = store
        let added = ioQueue.sync { store.insert(rows) ?? [] }
        guard !added.isEmpty else { return 0 }
        if Thread.isMainThread {
            MainActor.assumeIsolated { mergeRecent(added) }
        } else {
            DispatchQueue.main.async { self.mergeRecent(added) }
        }
        return added.count
    }

    private func mergeRecent(_ rows: [HistoryStore.Row]) {
        var merged = historyEvents + rows.map(Self.event)
        merged.sort { $0.timestamp > $1.timestamp }
        if merged.count > recentWindow { merged.removeLast(merged.count - recentWindow) }
        historyEvents = merged
    }

    // MARK: - Chat History Management

    func addConversationSummary(tabId: UUID, summary: ConversationSummary) {
        if conversationSummaries[tabId] == nil {
            conversationSummaries[tabId] = []
        }
        conversationSummaries[tabId]?.append(summary)
        scheduleSummariesSave()
    }
    
    func getSummariesForTab(tabId: UUID) -> [ConversationSummary] {
        return conversationSummaries[tabId] ?? []
    }
    
    // MARK: - Clear History
    
    enum ClearTimeframe {
        case today
        case thisWeek
        case last30Days
        case allTime
    }

    /// Start of the timeframe; nil for all time.
    static func cutoff(for timeframe: ClearTimeframe, now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        switch timeframe {
        case .today: return calendar.startOfDay(for: now)
        case .thisWeek: return calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .last30Days: return calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .allTime: return nil
        }
    }
    
    func clearHistory(timeframe: ClearTimeframe) {
        clearHistory(since: Self.cutoff(for: timeframe) ?? .distantPast)
    }
    
    /// Clears history and chat summaries from `cutoff` to now (Chrome's "Clear browsing data" time range).
    func clearHistory(since cutoff: Date) {
        historyEvents.removeAll { $0.timestamp >= cutoff }
        conversationSummaries = conversationSummaries.mapValues { $0.filter { $0.timestamp < cutoff } }.filter { !$0.value.isEmpty }
        let store = store
        ioQueue.async { cutoff == .distantPast ? store.deleteAll() : store.delete(since: cutoff) }
        scheduleSummariesSave()
    }

    func clearIndividualEvent(_ eventId: UUID) {
        historyEvents.removeAll { $0.id == eventId }
        let store = store
        ioQueue.async { store.delete(id: eventId) }
    }
    
    // MARK: - Persistence
    
    func flush() {
        pendingSummariesSave?.cancel()
        pendingSummariesSave = nil
        saveSummaries()
        // Drain both queues so data is guaranteed on disk (e.g. before app quit).
        ioQueue.sync {}
        saveQueue.sync {}
    }

    private func scheduleSummariesSave() {
        // An already pending save picks up this change too; rescheduling would let steady changes postpone it forever.
        guard pendingSummariesSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSummariesSave = nil
            self?.saveSummaries()
        }
        pendingSummariesSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Opens the store off the main thread: migrates the old JSON once, expires old visits,
    /// then loads the in-memory recent window.
    private func loadHistory(legacyJSON: URL) {
        let store = store, window = recentWindow
        ioQueue.async {
            store.migrateJSON(at: legacyJSON)
            store.expire()
            let rows = store.recent(limit: window)
            DispatchQueue.main.async { self.mergeRecent(rows) }
        }
    }
    
    private func saveSummaries() {
        guard persistent else { return }
        let snapshot = conversationSummaries
        let url = summariesFileURL
        saveQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("Failed to save summaries: \(error)")
            }
        }
    }
    
    private func loadSummaries() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard fileManager.fileExists(atPath: summariesFileURL.path),
              let data = try? Data(contentsOf: summariesFileURL),
              let summaries = try? decoder.decode([UUID: [ConversationSummary]].self, from: data) else {
            return
        }
        
        conversationSummaries = summaries
    }
    
    // MARK: - Query Methods

    /// History page: visits newest first, filtered by `query` (URL or title) when non-empty.
    func visits(matching query: String = "", limit: Int) async -> [HistoryEvent] {
        let rows = await self.query { query.isEmpty ? $0.recent(limit: limit) : $0.search(query, limit: limit) }
        return rows.map(Self.event)
    }

    // MARK: - URL bar autocomplete (history-based suggestions)

    /// Returns address-bar suggestions from browsing history. Matches query against URL and page title.
    /// Ranking: prefer (1) URLs with a meaningful path (e.g. discord.com/channels/@me over discord.com) so
    /// signed-in / frequently used pages surface first; (2) higher visit count; (3) more recent.
    /// display = page title if present, else host or URL.
    func urlAutocompleteSuggestions(prefix: String, limit: Int = 5) async -> [(display: String, url: URL)] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // shortcut: ranks only the 200 most-visited matching URLs; raise if path-ranked pages get crowded out.
        let matches = await query { $0.urlMatches(trimmed, limit: 200) }
        let ranked = matches.compactMap { m -> (match: HistoryStore.URLMatch, url: URL, hasPath: Bool)? in
            guard let url = URL(string: m.url) else { return nil }
            return (m, url, url.path.count > 1 && url.path != "/")
        }.sorted { a, b in
            if a.hasPath != b.hasPath { return a.hasPath }
            if a.match.visitCount != b.match.visitCount { return a.match.visitCount > b.match.visitCount }
            return a.match.lastVisit > b.match.lastVisit
        }
        return ranked.prefix(limit).map { ($0.match.title.isEmpty ? ($0.url.host ?? $0.url.absoluteString) : $0.match.title, $0.url) }
    }
}
