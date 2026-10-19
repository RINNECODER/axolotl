import Combine
import Foundation

/// Bounded, debounced per-profile chat persistence.
final class ChatStore: ObservableObject {
    @Published private(set) var messagesByTab: [UUID: [ChatMessage]] = [:]

    /// nil = in memory only (private windows).
    private let fileURL: URL?
    private var pendingSave: DispatchWorkItem?
    private let maxTabs = 100
    private let maxMessagesPerTab = 200
    /// Serial queue for disk writes so JSON encoding never blocks the main thread.
    private let saveQueue = DispatchQueue(label: "com.axolotl.chat-save", qos: .utility)

    init(profileId: UUID, persistent: Bool = true, fileManager: FileManager = .default) {
        guard persistent else { fileURL = nil; return }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Axolotl/Profiles/\(profileId.uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("chats.json")
        load()
    }

    // Avoid the MainActor isolated-deinit executor hop that double-frees
    // task-local storage on current macOS runtimes (swiftlang/swift#88036).
    nonisolated deinit {}

    func messages(for tabId: UUID) -> [ChatMessage] {
        messagesByTab[tabId] ?? []
    }

    func setMessages(_ messages: [ChatMessage], for tabId: UUID) {
        messagesByTab[tabId] = Array(messages.suffix(maxMessagesPerTab))
        trimTabsIfNeeded()
        scheduleSave()
    }

    func removeMessages(for tabId: UUID) {
        messagesByTab.removeValue(forKey: tabId)
        scheduleSave()
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
        // Drain the save queue so data is guaranteed on disk (e.g. before app quit).
        saveQueue.sync {}
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func saveNow() {
        guard let url = fileURL else { return }
        let snapshot = messagesByTab
        saveQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("Failed to save chats: \(error)")
            }
        }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([UUID: [ChatMessage]].self, from: data) else { return }
        messagesByTab = decoded.mapValues { Array($0.suffix(maxMessagesPerTab)) }
        trimTabsIfNeeded()
    }

    private func trimTabsIfNeeded() {
        guard messagesByTab.count > maxTabs else { return }
        let keep = messagesByTab
            .sorted { ($0.value.last?.timestamp ?? .distantPast) > ($1.value.last?.timestamp ?? .distantPast) }
            .prefix(maxTabs)
        messagesByTab = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}
