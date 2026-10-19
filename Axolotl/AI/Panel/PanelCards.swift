import Foundation

/// Structured content the panel renders as a card instead of Markdown.
/// Stored on `ChatMessage` (optional, so older chat history still decodes).
enum ChatCard: Codable, Equatable {
    case agentRun(AgentRunCard)
    case grab(GrabCard)
    case personalize(CustomizationCard)
}

/// A computer-use run as the panel shows it: one row per step, then an outcome line.
/// Built by folding `AgentEvent`s in order; no I/O, so it is tested from event lists.
struct AgentRunCard: Codable, Equatable {
    enum Status: String, Codable { case running, done, blocked, stopped, failed }

    struct Step: Codable, Equatable, Identifiable {
        var id: Int
        /// CLICK, TYPE_TEXT, SELECT, SCROLL_DOWN, WAIT…
        var operation: String
        /// The element's label, or "" for page-level actions.
        var target: String
        var confidence: Double?
        var latencyMs: Int
        /// What actually ran ("typed “x”"), once executed.
        var result: String?
        var noChange = false
        var executed = false
    }

    var goal: String
    var model: String
    var steps: [Step] = []
    var status: Status = .running
    /// Why the run ended, for blocked / failed.
    var reason: String?
    var elapsedMs: Int?
    /// The latest stale-page notice, shown under the steps while running.
    var note: String?

    var isRunning: Bool { status == .running }

    mutating func apply(_ event: AgentEvent) {
        switch event {
        case .observed:
            break
        case .decided(let d, let label):
            note = nil
            steps.append(Step(id: steps.count + 1, operation: Self.operationLabel(d.operation),
                              target: d.target == nil ? "" : label, confidence: d.confidence,
                              latencyMs: d.latencyMs))
        case .stale(let message):
            note = message
        case .executed(let r):
            guard !steps.isEmpty else { return }
            let i = steps.count - 1
            steps[i].executed = true
            steps[i].noChange = r.pageChanged == false
            steps[i].result = r.text.map { "“\($0)”" }
        case .finished(let outcome, _, let ms):
            elapsedMs = ms
            note = nil
            switch outcome {
            case .done: status = .done
            case .blocked(let why): status = .blocked; reason = why
            case .cancelled: status = .stopped
            case .failed(let why): status = .failed; reason = why
            }
        }
    }

    /// Stops a run whose task was cancelled before the agent reported it.
    mutating func markStopped() {
        if status == .running { status = .stopped; note = nil }
    }

    /// One line for the end of the run ("Done · 4 steps · 6.2 s").
    var outcomeLine: String {
        let n = steps.count
        let count = "\(n) step\(n == 1 ? "" : "s")"
        let time = elapsedMs.map { String(format: " · %.1f s", Double($0) / 1000) } ?? ""
        switch status {
        case .running: return "Running · \(count)"
        case .done: return "Done · \(count)\(time)"
        case .blocked: return "Blocked · \(count)\(time)"
        case .stopped: return "Stopped · \(count)"
        case .failed: return "Failed · \(count)\(time)"
        }
    }

    /// Plain text for chat history and the model's recent context.
    var transcript: String {
        var s = "Agent run: \(goal)\n\(outcomeLine)"
        if let reason { s += ": \(reason)" }
        return s
    }

    /// "TYPE_TEXT" → "Type", "SCROLL_DOWN" → "Scroll down".
    static func operationLabel(_ op: String) -> String {
        switch op.uppercased() {
        case "TYPE_TEXT": return "Type"
        case "DONE": return "Finish"
        case "BLOCKED": return "Give up"
        default:
            let words = op.lowercased().split(separator: "_").joined(separator: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}

/// A key grab: the agent's steps, then where the key was saved (never the value).
struct GrabCard: Codable, Equatable {
    enum Status: String, Codable { case running, waitingForSignIn, saved, notFound, failed, stopped }

    var serviceID: String
    var serviceName: String
    var keyName: String
    var run: AgentRunCard
    var status: Status = .running
    var message: String = ""
    /// "Axolotl API Keys / <account>", as Keychain Access shows it.
    var keychainItem: String?

    init(service: KeyService, keyName: String, model: String) {
        serviceID = service.id
        serviceName = service.name
        self.keyName = keyName
        run = AgentRunCard(goal: "Create a \(service.name) API key named “\(keyName)”", model: model)
    }

    mutating func finish(_ result: GrabResult) {
        message = result.message
        keychainItem = result.saved?.keychainItem
        run.markStopped()
        switch result.status {
        case .saved: status = .saved
        case .waitingForSignIn: status = .waitingForSignIn
        case .notFound: status = .notFound
        case .failed: status = .failed
        case .cancelled: status = .stopped
        }
    }

    var transcript: String {
        "Key grab: \(serviceName) “\(keyName)”\n" + (message.isEmpty ? run.outcomeLine : message)
    }
}
