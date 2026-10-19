// Ported from browser-use/jev-ultrafast (MIT License, Copyright (c) 2026 Browser Use):
// the predict/act loop in jev_ultrafast/agent.py.

import Foundation
import WebKit

/// Observe → one policy call → act only if the page still matches → record page_changed.
/// Stops on DONE, BLOCKED, three non-wait actions that changed nothing, or the step budget.
final class ComputerUseAgent {
    let driver: AgentPageDriving
    let policy: AgentPolicy
    let textProvider: FieldTextProviding
    let maxSteps: Int
    /// Checked before every model call; a non-nil outcome ends the run without asking the model.
    /// The key grabber uses it to stop the moment a key is captured or a sign-in page appears.
    var shouldStop: () -> AgentOutcome? = { nil }

    init(driver: AgentPageDriving, policy: AgentPolicy,
         textProvider: FieldTextProviding = LLMFieldTextProvider(), maxSteps: Int = AgentPrompts.maxSteps) {
        self.driver = driver
        self.policy = policy
        self.textProvider = textProvider
        self.maxSteps = maxSteps
    }

    /// Jev when a TypeSafe key is saved, otherwise the user's chat model.
    /// Use `AxolotlToolbox.agent(for:)`, which shares the tab's driver with the tools.
    static func make(driver: AgentPageDriving, maxSteps: Int = AgentPrompts.maxSteps) -> ComputerUseAgent {
        ComputerUseAgent(driver: driver, policy: defaultPolicy(), maxSteps: maxSteps)
    }

    /// Jev when a TypeSafe key is set, else the chat model.
    static func defaultPolicy() -> AgentPolicy {
        if let key = KeychainManager.shared.string(for: .typesafeKey), !key.isEmpty {
            return JevPolicy(client: JevClient(apiKey: key))
        }
        return LLMPolicy()
    }

    /// Streams step events. Cancelling the consuming task (or dropping the stream) stops the run.
    func run(goal: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                _ = await self.execute(goal: goal) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    func execute(goal: String, emit: (AgentEvent) -> Void = { _ in }) async -> AgentOutcome {
        let started = Date()
        var history: [AgentStepRecord] = []
        var calls = 0
        var pendingText: (key: String, text: String)?

        func finish(_ outcome: AgentOutcome) -> AgentOutcome {
            emit(.finished(outcome, steps: history.count, elapsedMs: Int(Date().timeIntervalSince(started) * 1000)))
            return outcome
        }
        func observe() async throws -> PageSnapshot {
            let s = try await driver.snapshot()
            emit(.observed(url: s.url, title: s.title, actions: s.actions.count))
            return s
        }

        do {
            var page = try await observe()
            while true {
                try Task.checkCancellation()
                if calls >= maxSteps * 2 { return finish(.blocked("Reached the model-call budget.")) }
                if !(await driver.isFresh(page, for: nil)) { page = try await observe() }
                if let stop = shouldStop() { return finish(stop) }
                let decision = try await policy.decide(snapshot: page, goal: goal, history: history)
                calls += 1
                try Task.checkCancellation()
                emit(.decided(decision, label: page.action(id: decision.choice)?.label ?? decision.choice))

                // A decision is consumed once: every path below either acts on it or re-observes.
                if decision.choice == "DONE" || decision.choice == "BLOCKED" {
                    guard await driver.isFresh(page, for: nil) else {
                        emit(.stale("Page changed since the decision. Choosing again."))
                        page = try await observe()
                        continue
                    }
                    return finish(decision.choice == "DONE" ? .done : .blocked("No supported operation can progress."))
                }
                guard let action = page.action(id: decision.choice) else {
                    throw AgentError.invalidResponse("Decision refers to no observed action; nothing executed.")
                }
                if history.count >= maxSteps { return finish(.blocked("Stopped at the \(maxSteps)-action budget.")) }

                var text: String?
                if action.kind == "fill" {
                    guard await driver.isFresh(page, for: nil) else {
                        emit(.stale("Page changed before text generation. Choosing again."))
                        page = try await observe()
                        continue
                    }
                    let context = AgentContext.field(goal: goal, action: action, snapshot: page, history: history)
                    let key = context.jsonString()
                    if let pending = pendingText, pending.key == key {
                        text = pending.text
                    } else {
                        let value = try await textProvider.text(for: context)
                        pendingText = (key, value)
                        text = value
                    }
                    try Task.checkCancellation()
                }

                // Freshness is checked immediately before input, including after text generation.
                guard await driver.isFresh(page, for: action) else {
                    emit(.stale("Page changed since this decision. Observing again."))
                    page = try await observe()
                    continue
                }
                try Task.checkCancellation()
                do {
                    try await driver.perform(action, text: text)
                } catch AgentError.stalePage(let message) {
                    emit(.stale(message))
                    page = try await observe()
                    continue
                }
                pendingText = nil
                // Record execution before observing: a failed observation must not erase the action.
                history.append(AgentStepRecord(
                    step: history.count + 1, action: action.label, kind: action.kind, choice: decision.choice,
                    operation: decision.operation, text: text, confidence: decision.confidence,
                    latencyMs: decision.latencyMs, url: page.url, pageChanged: nil))
                await driver.settle(after: action)
                let next = try await driver.snapshot()
                history[history.count - 1].pageChanged = next.fingerprint != page.fingerprint
                history[history.count - 1].url = next.url
                emit(.executed(history[history.count - 1]))
                page = next
                emit(.observed(url: page.url, title: page.title, actions: page.actions.count))

                let recent = history.suffix(3)
                if recent.count == 3, recent.allSatisfy({ $0.pageChanged == false && $0.kind != "wait" }) {
                    return finish(.blocked("The last 3 actions changed nothing on the page."))
                }
            }
        } catch is CancellationError {
            return finish(.cancelled)
        } catch {
            return finish(Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
        }
    }
}

extension AgentEvent {
    /// One Markdown line for the AI panel, or nil for events not worth showing.
    var panelLine: String? {
        switch self {
        case .observed:
            return nil
        case .decided(let d, let label):
            let conf = d.confidence.map { String(format: " · %.0f%%", $0 * 100) } ?? ""
            let target = d.target == nil ? "" : " → \(label)"
            return "**\(d.operation)**\(target)\(conf) · \(d.latencyMs) ms"
        case .stale(let message):
            return "_\(message)_"
        case .executed(let r):
            let typed = r.text.map { " “\($0)”" } ?? ""
            return "  \(r.step). \(r.kind)\(typed)\(r.pageChanged == false ? " (no change)" : "")"
        case .finished(let outcome, let steps, let ms):
            let seconds = String(format: "%.1f s", Double(ms) / 1000)
            switch outcome {
            case .done: return "\n**Done** in \(steps) steps, \(seconds)."
            case .blocked(let why): return "\n**Blocked** after \(steps) steps: \(why)"
            case .cancelled: return "\n*[Agent stopped]*"
            case .failed(let why): return "\n**Stopped:** \(why)"
            }
        }
    }
}
