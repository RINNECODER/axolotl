// Luma MVP - History Management System
import Foundation
import Combine

/// Manages persistent storage of browsing history and chat conversations.
/// Stores data on disk in Application Support directory.
final class HistoryManager: ObservableObject {
    @Published private(set) var historyEvents: [HistoryEvent] = []
    @Published private(set) var conversationSummaries: [UUID: [ConversationSummary]] = [:] // tabId -> summaries
    
    private let fileManager = FileManager.default
    private let profileId: UUID
    private let historyFileName = "browsing_history.json"
    private let summariesFileName = "conversation_summaries.json"
    private let maxHistoryCount = 10_000
    private var pendingHistorySave: DispatchWorkItem?
    private var pendingSummariesSave: DispatchWorkItem?
    /// Serial queue for disk writes so JSON encoding of large histories never blocks the main thread.
    private let saveQueue = DispatchQueue(label: "com.luna.history-save", qos: .utility)
    
    private var historyFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let lumaDir = appSupport.appendingPathComponent("Luna/Profiles/\(profileId.uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: lumaDir, withIntermediateDirectories: true)
        return lumaDir.appendingPathComponent(historyFileName)
    }
    
    private var summariesFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let lumaDir = appSupport.appendingPathComponent("Luna/Profiles/\(profileId.uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: lumaDir, withIntermediateDirectories: true)
        return lumaDir.appendingPathComponent(summariesFileName)
    }
    
    init(profileId: UUID) {
        self.profileId = profileId
        loadHistory()
        loadSummaries()
    }

    // Avoid the MainActor isolated-deinit executor hop that double-frees
    // task-local storage on current macOS runtimes (swiftlang/swift#88036).
    nonisolated deinit {}
    
    // MARK: - Page Visit Tracking
    
    func recordPageVisit(url: URL, title: String) {
        guard url.scheme == "http" || url.scheme == "https" || url.scheme == "file" else { return }
        if let latest = historyEvents.first,
           latest.type == .pageVisit,
           latest.url == url.absoluteString,
           Date().timeIntervalSince(latest.timestamp) < 2 {
            return
        }
        let event = HistoryEvent(
            timestamp: Date(),
            type: .pageVisit,
            url: url.absoluteString,
            pageTitle: title
        )
        historyEvents.insert(event, at: 0)
        if historyEvents.count > maxHistoryCount {
            historyEvents.removeLast(historyEvents.count - maxHistoryCount)
        }
        scheduleHistorySave()
    }
    
    /// Adds visits imported from another browser. Skips visits already present
    /// (same URL within the same second), keeps newest-first order and the cap.
    /// Returns how many were added.
    @discardableResult
    func importVisits(_ visits: [ImportedVisit]) -> Int {
        guard !visits.isEmpty else { return 0 }
        func key(_ url: String, _ date: Date) -> String { "\(Int(date.timeIntervalSince1970))|\(url)" }
        var seen = Set(historyEvents.lazy.filter { $0.type == .pageVisit }.compactMap { e in e.url.map { key($0, e.timestamp) } })
        var added: [HistoryEvent] = []
        for v in visits where seen.insert(key(v.url, v.date)).inserted {
            added.append(HistoryEvent(timestamp: v.date, type: .pageVisit, url: v.url, pageTitle: v.title))
        }
        guard !added.isEmpty else { return 0 }
        var merged = historyEvents + added
        merged.sort { $0.timestamp > $1.timestamp }
        if merged.count > maxHistoryCount { merged.removeLast(merged.count - maxHistoryCount) }
        let kept = Set(merged.map(\.id))
        historyEvents = merged
        scheduleHistorySave()
        return added.filter { kept.contains($0.id) }.count
    }

    // MARK: - Chat History Management

    /// Records a chat session. sessionId = tabId so all chats in the same tab belong to one session until the tab is closed.
    func recordChatSession(tabId: UUID, messages: [ChatMessage], summary: String? = nil) {
        let event = HistoryEvent(
            timestamp: Date(),
            type: .chatConversation,
            sessionId: tabId,
            chatMessages: messages,
            conversationSummary: summary
        )
        historyEvents.insert(event, at: 0)
        if historyEvents.count > maxHistoryCount {
            historyEvents.removeLast(historyEvents.count - maxHistoryCount)
        }
        scheduleHistorySave()
    }
    
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
    
    func clearHistory(timeframe: ClearTimeframe) {
        let now = Date()
        let calendar = Calendar.current
        
        let cutoffDate: Date
        switch timeframe {
        case .today:
            cutoffDate = calendar.startOfDay(for: now)
        case .thisWeek:
            cutoffDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .last30Days:
            cutoffDate = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .allTime:
            historyEvents.removeAll()
            conversationSummaries.removeAll()
            scheduleHistorySave()
            scheduleSummariesSave()
            return
        }
        
        historyEvents.removeAll { $0.timestamp >= cutoffDate }
        conversationSummaries = conversationSummaries.mapValues { summaries in
            summaries.filter { $0.timestamp < cutoffDate }
        }.filter { !$0.value.isEmpty }
        scheduleHistorySave()
        scheduleSummariesSave()
    }
    
    func clearIndividualEvent(_ eventId: UUID) {
        historyEvents.removeAll { $0.id == eventId }
        scheduleHistorySave()
    }
    
    func clearChatHistoryForTab(_ tabId: UUID) {
        conversationSummaries.removeValue(forKey: tabId)
        scheduleSummariesSave()
    }
    
    // MARK: - Persistence
    
    func flush() {
        pendingHistorySave?.cancel()
        pendingSummariesSave?.cancel()
        pendingHistorySave = nil
        pendingSummariesSave = nil
        saveHistory()
        saveSummaries()
        // Drain the save queue so data is guaranteed on disk (e.g. before app quit).
        saveQueue.sync {}
    }

    private func scheduleHistorySave() {
        pendingHistorySave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveHistory() }
        pendingHistorySave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scheduleSummariesSave() {
        pendingSummariesSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSummaries() }
        pendingSummariesSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveHistory() {
        let snapshot = historyEvents
        let url = historyFileURL
        saveQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("Failed to save history: \(error)")
            }
        }
    }
    
    private func loadHistory() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard fileManager.fileExists(atPath: historyFileURL.path),
              let data = try? Data(contentsOf: historyFileURL),
              let events = try? decoder.decode([HistoryEvent].self, from: data) else {
            return
        }
        
        historyEvents = events
    }
    
    private func saveSummaries() {
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
    
    func getHistory(for timeframe: ClearTimeframe) -> [HistoryEvent] {
        let now = Date()
        let calendar = Calendar.current
        
        let cutoffDate: Date
        switch timeframe {
        case .today:
            cutoffDate = calendar.startOfDay(for: now)
        case .thisWeek:
            cutoffDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .last30Days:
            cutoffDate = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .allTime:
            return historyEvents
        }
        
        return historyEvents.filter { $0.timestamp >= cutoffDate }
    }
    
    func searchHistory(query: String) -> [HistoryEvent] {
        let lowercased = query.lowercased()
        return historyEvents.filter { event in
            if let title = event.pageTitle, title.lowercased().contains(lowercased) {
                return true
            }
            if let url = event.url, url.lowercased().contains(lowercased) {
                return true
            }
            if let messages = event.chatMessages {
                return messages.contains { $0.text.lowercased().contains(lowercased) }
            }
            return false
        }
    }

    // MARK: - URL bar autocomplete (history-based suggestions)

    /// Returns address-bar suggestions from browsing history. Matches query against URL and page title.
    /// Ranking: prefer (1) URLs with a meaningful path (e.g. discord.com/channels/@me over discord.com) so
    /// signed-in / frequently used pages surface first; (2) higher visit count; (3) more recent.
    /// display = page title if present, else host or URL.
    func urlAutocompleteSuggestions(prefix: String, limit: Int = 5) -> [(display: String, url: URL)] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        // Group by URL: (visitCount, mostRecentTimestamp, display from most recent title)
        struct URLInfo {
            var visitCount: Int
            var mostRecent: Date
            var display: String
            var url: URL
            var hasMeaningfulPath: Bool
        }
        var byURL: [String: URLInfo] = [:]
        for event in historyEvents where event.type == .pageVisit {
            guard let urlString = event.url, let url = URL(string: urlString) else { continue }
            let urlMatch = urlString.lowercased().contains(trimmed)
            let titleMatch = event.pageTitle?.lowercased().contains(trimmed) ?? false
            if !urlMatch && !titleMatch { continue }

            let path = url.path
            let hasPath = path.count > 1 && path != "/"

            if let existing = byURL[urlString] {
                let isNewer = event.timestamp > existing.mostRecent
                let display = (!(event.pageTitle?.isEmpty ?? true)) ? (event.pageTitle ?? "") : (url.host ?? url.absoluteString)
                byURL[urlString] = URLInfo(
                    visitCount: existing.visitCount + 1,
                    mostRecent: isNewer ? event.timestamp : existing.mostRecent,
                    display: isNewer ? display : existing.display,
                    url: url,
                    hasMeaningfulPath: hasPath || existing.hasMeaningfulPath
                )
            } else {
                let display = (!(event.pageTitle?.isEmpty ?? true)) ? (event.pageTitle ?? "") : (url.host ?? url.absoluteString)
                byURL[urlString] = URLInfo(
                    visitCount: 1,
                    mostRecent: event.timestamp,
                    display: display,
                    url: url,
                    hasMeaningfulPath: hasPath
                )
            }
        }

        let sorted = byURL.values.sorted { a, b in
            // Prefer URLs with path (e.g. /channels/@me, /courses) over bare domain
            if a.hasMeaningfulPath != b.hasMeaningfulPath { return a.hasMeaningfulPath }
            // Then by visit count (more visits = more likely where user wants to go)
            if a.visitCount != b.visitCount { return a.visitCount > b.visitCount }
            // Then by recency
            return a.mostRecent > b.mostRecent
        }
        return Array(sorted.prefix(limit).map { ($0.display, $0.url) })
    }
}
