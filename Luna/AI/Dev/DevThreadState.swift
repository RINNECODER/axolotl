import Foundation

/// The Dev mode thread as the UI shows it, built by folding `CLIEvent`s in order.
/// A value type with no I/O so the reduction can be tested from captured CLI output.
struct DevThreadState: Equatable {
    struct ToolCard: Equatable {
        enum Status: Equatable { case running, done, failed }
        let id: String
        let name: String
        let summary: String
        var output: String = ""
        var status: Status = .running
    }

    struct ApprovalCard: Equatable {
        enum Status: Equatable { case pending, decided(CLIApprovalDecision), expired }
        let request: CLIApprovalRequest
        var status: Status = .pending
        var isPending: Bool { status == .pending }
    }

    struct TurnFooter: Equatable {
        let outcome: CLITurnOutcome
        let inputTokens: Int?
        let outputTokens: Int?
        /// This turn's cost (Claude reports a running session total; the delta is stored here).
        let costUSD: Double?
    }

    enum Item: Equatable {
        case user(String)
        case assistant(text: String, streaming: Bool)
        case tool(ToolCard)
        case approval(ApprovalCard)
        case turn(TurnFooter)
        case error(String)
        case crash(status: Int32, signaled: Bool, stderrTail: String)
    }

    let kind: AgentCLIKind
    private(set) var items: [Item] = []
    private(set) var sessionID: String?
    /// True while a process is attached and has not exited.
    private(set) var isAlive = false
    /// True from a send until the matching `turnDone` (or exit).
    private(set) var isTurnActive = false
    /// Messages sent while a turn was running (Claude queues them; each gets its own turnDone).
    private var queuedTurns = 0
    private var lastCumulativeCost: Double?

    /// Longest tool output kept per card (the tail is what matters while it runs).
    static let toolOutputLimit = 20_000

    init(kind: AgentCLIKind) { self.kind = kind }

    var pendingApprovals: Int {
        items.reduce(0) { n, item in if case .approval(let a) = item, a.isPending { return n + 1 }; return n }
    }

    /// Codex rejects a new message mid-turn (`.busy`); Claude queues it.
    var canSend: Bool {
        isAlive && (kind == .claudeCode || !isTurnActive)
    }

    /// Total reported cost so far (Claude only; Codex does not report one).
    var sessionCostUSD: Double? { lastCumulativeCost }

    mutating func attached() {
        isAlive = true
    }

    mutating func userSent(_ text: String) {
        closeStreamingText()
        items.append(.user(text))
        if isTurnActive { queuedTurns += 1 }
        isTurnActive = true
    }

    mutating func decided(approvalID: String, _ decision: CLIApprovalDecision) {
        guard let i = approvalIndex(approvalID) else { return }
        if case .approval(var card) = items[i], card.isPending {
            card.status = .decided(decision)
            items[i] = .approval(card)
        }
    }

    /// A local failure (e.g. the CLI rejected a send) shown inline.
    mutating func note(error: String) {
        items.append(.error(error))
    }

    mutating func apply(_ event: CLIEvent) {
        switch event {
        case .sessionStarted(let id):
            sessionID = id

        case .userMessage(let text):
            closeStreamingText()
            items.append(.user(text))

        case .textDelta(let delta):
            if case .assistant(let text, true)? = items.last {
                items[items.count - 1] = .assistant(text: text + delta, streaming: true)
            } else {
                items.append(.assistant(text: delta, streaming: true))
            }

        case .messageDone(let full):
            if case .assistant(_, true)? = items.last {
                items[items.count - 1] = .assistant(text: full.isEmpty ? currentText : full, streaming: false)
            } else if !full.isEmpty, lastAssistantText != full {
                items.append(.assistant(text: full, streaming: false))
            }

        case .toolStarted(let id, let name, let summary):
            closeStreamingText()
            if toolIndex(id) == nil {
                items.append(.tool(ToolCard(id: id, name: name, summary: summary)))
            }

        case .toolOutput(let id, let text):
            guard let i = toolIndex(id), case .tool(var card) = items[i] else { return }
            card.output += text
            if card.output.count > Self.toolOutputLimit {
                card.output = "…" + String(card.output.suffix(Self.toolOutputLimit))
            }
            items[i] = .tool(card)

        case .toolFinished(let id, let isError):
            guard let i = toolIndex(id), case .tool(var card) = items[i] else { return }
            card.status = isError ? .failed : .done
            items[i] = .tool(card)

        case .approvalRequest(let request):
            closeStreamingText()
            items.append(.approval(ApprovalCard(request: request)))

        case .turnDone(let usage, let outcome):
            closeStreamingText()
            expirePendingApprovals()
            var turnCost: Double?
            if let total = usage?.costUSD {
                if kind == .claudeCode {
                    turnCost = max(0, total - (lastCumulativeCost ?? 0))
                    lastCumulativeCost = total
                } else {
                    turnCost = total
                }
            }
            items.append(.turn(TurnFooter(outcome: outcome, inputTokens: usage?.inputTokens,
                                          outputTokens: usage?.outputTokens, costUSD: turnCost)))
            if queuedTurns > 0 { queuedTurns -= 1 } else { isTurnActive = false }

        case .error(let message):
            items.append(.error(message))

        case .exited(let exit):
            closeStreamingText()
            expirePendingApprovals()
            for i in items.indices {
                if case .tool(var card) = items[i], card.status == .running {
                    card.status = exit.expected ? .done : .failed
                    items[i] = .tool(card)
                }
            }
            isAlive = false
            isTurnActive = false
            queuedTurns = 0
            if !exit.expected {
                items.append(.crash(status: exit.status, signaled: exit.signaled, stderrTail: exit.stderrTail))
            }
        }
    }

    // MARK: Helpers

    private var currentText: String {
        if case .assistant(let text, _)? = items.last { return text }
        return ""
    }

    private var lastAssistantText: String? {
        for item in items.reversed() {
            if case .assistant(let text, _) = item { return text }
            if case .user = item { return nil }
        }
        return nil
    }

    private mutating func closeStreamingText() {
        if case .assistant(let text, true)? = items.last {
            items[items.count - 1] = .assistant(text: text, streaming: false)
        }
    }

    private mutating func expirePendingApprovals() {
        for i in items.indices {
            if case .approval(var card) = items[i], card.isPending {
                card.status = .expired
                items[i] = .approval(card)
            }
        }
    }

    private func toolIndex(_ id: String) -> Int? {
        items.lastIndex { if case .tool(let c) = $0 { return c.id == id }; return false }
    }

    private func approvalIndex(_ id: String) -> Int? {
        items.lastIndex { if case .approval(let c) = $0 { return c.request.id == id }; return false }
    }
}

// MARK: - Approval details

enum DevApprovalText {
    /// What the approval is actually about, from the raw request: the command to run, or the
    /// file change as a small diff. Falls back to the pretty-printed payload.
    static func detail(for request: CLIApprovalRequest) -> String {
        let payload = request.payload
        if let command = find(["command", "cmd"], in: payload) {
            return "$ " + command
        }
        if let old = find(["old_string"], in: payload), let new = find(["new_string"], in: payload) {
            let path = find(["file_path", "path"], in: payload).map { $0 + "\n" } ?? ""
            return path + diff(old: old, new: new)
        }
        if let patch = find(["unified_diff", "diff", "patch"], in: payload) {
            return patch
        }
        if let content = find(["content"], in: payload) {
            let path = find(["file_path", "path"], in: payload).map { $0 + "\n" } ?? ""
            return path + content.split(separator: "\n", omittingEmptySubsequences: false).map { "+ " + $0 }.joined(separator: "\n")
        }
        return pretty(payload)
    }

    static func diff(old: String, new: String) -> String {
        let minus = old.split(separator: "\n", omittingEmptySubsequences: false).map { "- " + $0 }
        let plus = new.split(separator: "\n", omittingEmptySubsequences: false).map { "+ " + $0 }
        return (minus + plus).joined(separator: "\n")
    }

    /// Depth-first search for the first string (or array of strings) under any of `keys`.
    static func find(_ keys: [String], in value: JSONValue) -> String? {
        switch value {
        case .object(let object):
            for key in keys {
                if let s = object[key]?.stringValue, !s.isEmpty { return s }
                if case .array(let parts)? = object[key] {
                    let strings = parts.compactMap(\.stringValue)
                    if !strings.isEmpty, strings.count == parts.count { return strings.joined(separator: " ") }
                }
            }
            for key in object.keys.sorted() {
                if let found = find(keys, in: object[key]!) { return found }
            }
        case .array(let values):
            for v in values { if let found = find(keys, in: v) { return found } }
        default:
            break
        }
        return nil
    }

    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return value.jsonString() }
        return String(decoding: data, as: UTF8.self)
    }
}
