import AppKit
import Observation

/// Routes outside-agent approval requests to an open AI panel as an inline card.
/// When no panel is on screen, `ask` returns nil and the caller falls back to an alert.
@MainActor
@Observable
final class MCPApprovalCenter {
    static let shared = MCPApprovalCenter()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let client: String
        let tool: String
        let detail: String

        /// Customization tools show a change preview with Apply / Cancel.
        var isPreview: Bool { PersonalizationTools.previewNames.contains(tool) }

        var title: String {
            if isPreview { return "\(client) proposes: \(Self.previewTitles[tool] ?? "a change")" }
            // "tabs_list" -> "list tabs": verb first, no internal tool names.
            let parts = tool.split(separator: "_").map(String.init)
            let phrase = parts.count == 2 ? "\(parts[1]) \(parts[0])" : parts.joined(separator: " ")
            return "\(client) wants to \(phrase)"
        }

        static let previewTitles = [
            "settings_set": "change Luna settings", "tabs_group": "group tabs", "tabs_reorder": "reorder tabs",
            "tab_pin": "pin a tab", "favorites_add": "add a favorite", "bookmarks_add": "add a bookmark",
            "undo_change": "undo a change",
        ]
    }

    private(set) var pending: [Request] = []
    private var waiting: [UUID: CheckedContinuation<MCPApproval, Never>] = [:]
    /// Panels currently on screen (each registers on appear, unregisters on disappear).
    private(set) var visiblePanels = 0

    func panelAppeared() { visiblePanels += 1 }
    func panelDisappeared() { visiblePanels = max(0, visiblePanels - 1) }

    /// Shows the request in the open panel and waits for a decision, or nil when no panel is open.
    func ask(client: String, tool: String, detail: String, timeout: TimeInterval) async -> MCPApproval? {
        guard visiblePanels > 0 else { return nil }
        let request = Request(client: client, tool: tool, detail: detail)
        pending.append(request)
        NSApp.requestUserAttention(.informationalRequest)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.resolve(request.id, .deny)
        }
        return await withCheckedContinuation { cont in waiting[request.id] = cont }
    }

    func resolve(_ id: UUID, _ decision: MCPApproval) {
        pending.removeAll { $0.id == id }
        waiting.removeValue(forKey: id)?.resume(returning: decision)
    }
}
