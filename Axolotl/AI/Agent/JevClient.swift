// Ported from browser-use/jev-ultrafast (MIT License, Copyright (c) 2026 Browser Use):
// post_json, validate_choice, choose and field_text in jev_ultrafast/model.py.

import Foundation

// MARK: - Transport

/// HTTP seam so the client can be tested without the network.
protocol AgentHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionAgentTransport: AgentHTTPTransport {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: - Policies

/// Picks one operation (+ target) for the current page. Jev or the user's chat model.
protocol AgentPolicy {
    func decide(snapshot: PageSnapshot, goal: String, history: [AgentStepRecord]) async throws -> AgentDecision
}

/// Writes the value for a TYPE_TEXT step.
protocol FieldTextProviding {
    func text(for context: JSONValue) async throws -> String
}

enum AgentContext {
    static func recentActions(_ history: [AgentStepRecord]) -> JSONValue {
        .array(history.suffix(10).map { h in
            .object(["action": .string(h.action), "kind": .string(h.kind),
                     "text": h.text.map(JSONValue.string) ?? .null,
                     "page_changed": h.pageChanged.map(JSONValue.bool) ?? .null])
        })
    }

    static func page(_ s: PageSnapshot) -> JSONValue {
        .object(["url": .string(s.url), "title": .string(s.title), "text": .string(s.text)])
    }

    static func field(goal: String, action: PageAction, snapshot: PageSnapshot, history: [AgentStepRecord]) -> JSONValue {
        .object([
            "goal": .string(goal),
            "field": .object(["label": .string(action.label),
                              "role": action.role.map(JSONValue.string) ?? .null,
                              "value": action.value.map(JSONValue.string) ?? .null]),
            "page": .object(["title": .string(snapshot.title), "text": .string(String(snapshot.text.prefix(6000)))]),
            "recent_actions": .array(history.suffix(6).map { h in
                .object(["action": .string(h.action), "text": h.text.map(JSONValue.string) ?? .null])
            }),
        ])
    }

    /// Per-target criteria shared by Jev and the LLM fallback.
    static func targetCriteria(_ candidates: [String: PageAction]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for (index, a) in candidates {
            var c: [String: JSONValue] = [
                "element": .string("[\(index)] \(a.label)"),
                "current_value": .string(a.currentValue ?? a.value ?? ""),
            ]
            if let v = a.role { c["role"] = .string(v) }
            if let v = a.checked { c["checked"] = .string(v) }
            if let v = a.selected { c["selected"] = .string(v) }
            if let v = a.expanded { c["expanded"] = .string(v) }
            out[index] = .object(c)
        }
        return .object(out)
    }
}

// MARK: - Jev

/// Client for TypeSafe System One (`/v1/systemone`). The API key is only ever placed
/// in the Authorization header; it is never logged or included in errors.
final class JevClient {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let defaultModel = "jev-1.14.0"
    static let modelDefaultsKey = "axolotl_jev_model"

    static var configuredModel: String {
        let m = ModelPrefs.string(modelDefaultsKey).trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? defaultModel : m
    }

    private let apiKey: String
    let model: String
    private let transport: AgentHTTPTransport
    private let retryDelay: (Int) -> UInt64

    init(apiKey: String, model: String = JevClient.configuredModel,
         transport: AgentHTTPTransport = URLSessionAgentTransport(),
         retryDelayNanos: @escaping (Int) -> UInt64 = { UInt64(0.5 * pow(2, Double($0)) * 1e9) }) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.retryDelay = retryDelayNanos
    }

    struct Choice: Equatable {
        var choice: String
        var probabilities: [String: Double]
        var confidence: Double
    }

    /// Request body for one step. `choose` sends exactly this.
    func requestBody(snapshot: PageSnapshot, goal: String, history: [AgentStepRecord]) -> (JSONValue, ActionSpace) {
        let space = ActionSpace(snapshot.actions)
        var questions: [String: JSONValue] = [
            "operation": .object([
                "type": "choice",
                "criteria": .object(space.operations.mapValues(JSONValue.string)),
                "instructions": .object(["goal": .string(goal), "rules": .string(AgentPrompts.nextAction)]),
            ]),
        ]
        for (operation, candidates) in space.targets {
            questions[operation.lowercased() + "_target"] = .object([
                "type": "choice",
                "criteria": AgentContext.targetCriteria(candidates),
                "instructions": .object([
                    "goal": .string(goal), "operation": .string(operation),
                    "rules": .array([.string(AgentPrompts.nextAction), .string(AgentPrompts.target)]),
                ]),
            ])
        }
        let body: JSONValue = .object([
            "model": .string(model),
            "state": .object([
                "page": AgentContext.page(snapshot),
                "elements": .array(space.elements),
                "recent_actions": AgentContext.recentActions(history),
            ]),
            "questions": .object(questions),
        ])
        return (body, space)
    }

    func choose(snapshot: PageSnapshot, goal: String, history: [AgentStepRecord]) async throws -> AgentDecision {
        let (body, space) = requestBody(snapshot: snapshot, goal: goal, history: history)
        let started = Date()
        let result = try await post(body)
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        let operations = space.operations
        let op = try Self.validateChoice(result["answers"]?["operation"], ids: Set(operations.keys))
        var target: String?
        var probability = op.probabilities[op.choice]
        if let candidates = space.targets[op.choice] {
            // Unused target heads cannot cause an action. Validate the head selected by the operation.
            let t = try Self.validateChoice(result["answers"]?[op.choice.lowercased() + "_target"],
                                            ids: Set(candidates.keys))
            target = t.choice
            probability = t.probabilities[t.choice]
        }
        guard let choice = space.actionID(operation: op.choice, target: target) else {
            throw AgentError.invalidResponse("Invalid TypeSafe response; no action executed.")
        }
        return AgentDecision(choice: choice, operation: op.choice, target: target, confidence: op.confidence,
                             probability: probability, latencyMs: latency,
                             model: result["model"]?.stringValue ?? model)
    }

    /// The choice must be an offered id and the argmax of a probability map over exactly
    /// the offered ids that sums to 1; all numbers finite in [0, 1].
    static func validateChoice(_ answer: JSONValue?, ids: Set<String>) throws -> Choice {
        let invalid = AgentError.invalidResponse("Invalid TypeSafe response; no action executed.")
        guard let answer, let choice = answer["choice"]?.stringValue,
              let probs = answer["probabilities"]?.objectValue,
              let confidence = answer["confidence"]?.numberValue else { throw invalid }
        var probabilities: [String: Double] = [:]
        for (k, v) in probs {
            guard let n = v.numberValue else { throw invalid }
            probabilities[k] = n
        }
        let numbers = Array(probabilities.values) + [confidence]
        guard ids.contains(choice), Set(probabilities.keys) == ids,
              numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              abs(probabilities.values.reduce(0, +) - 1) < 0.02,
              let chosen = probabilities[choice], chosen >= (probabilities.values.max() ?? 0) - 1e-6
        else { throw invalid }
        return Choice(choice: choice, probabilities: probabilities, confidence: confidence)
    }

    /// POST with retries on 429/503/529 (3 attempts, 0.5s·2^n backoff).
    static let modelsEndpoint = URL(string: "https://api.typesafe.ai/v1/models")!

    /// Models the TypeSafe account can use, for the Settings picker.
    static func listModels(apiKey: String,
                           transport: AgentHTTPTransport = URLSessionAgentTransport()) async throws -> [(id: String, name: String)] {
        var request = URLRequest(url: modelsEndpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await transport.send(request)
        guard (200..<300).contains(status) else {
            throw AgentError.transport("TypeSafe returned HTTP \(status) for the model list.")
        }
        guard case .array(let models)? = (try? JSONDecoder().decode(JSONValue.self, from: data))?["models"] else {
            throw AgentError.invalidResponse("Invalid TypeSafe model list.")
        }
        return models.compactMap { $0["name"]?.stringValue }.map { ($0, $0) }
    }

    private func post(_ body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONValue.encoder.encode(body)
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let data: Data, status: Int
            do {
                (data, status) = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw AgentError.transport("Jev connection failed; no action executed.")
            }
            if [429, 503, 529].contains(status), attempt < 2 {
                try await Task.sleep(nanoseconds: retryDelay(attempt))
                continue
            }
            guard (200..<300).contains(status) else {
                throw AgentError.transport("Jev returned HTTP \(status); no action executed.")
            }
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw AgentError.invalidResponse("Invalid TypeSafe response; no action executed.")
            }
            return json
        }
        throw AgentError.transport("Jev unavailable; no action executed.")
    }
}

struct JevPolicy: AgentPolicy {
    let client: JevClient

    func decide(snapshot: PageSnapshot, goal: String, history: [AgentStepRecord]) async throws -> AgentDecision {
        try await client.choose(snapshot: snapshot, goal: goal, history: history)
    }
}

// MARK: - No-key fallback

/// Asks the user's chosen chat model for the same `{operation, target}` from the same
/// element table, one call per step. Ids are validated like Jev's; it reports no probabilities.
struct LLMPolicy: AgentPolicy {
    var complete: (LLMRequest) async throws -> String = { try await LLMService.shared.complete($0) }
    var modelName: String = LLMService.shared.modelName

    func decide(snapshot: PageSnapshot, goal: String, history: [AgentStepRecord]) async throws -> AgentDecision {
        let space = ActionSpace(snapshot.actions)
        let state: JSONValue = .object([
            "goal": .string(goal),
            "page": AgentContext.page(snapshot),
            "elements": .array(space.elements),
            "recent_actions": AgentContext.recentActions(history),
            "operations": .object(space.operations.mapValues(JSONValue.string)),
            "targets": .object(space.targets.mapValues(AgentContext.targetCriteria)),
        ])
        let system = """
        You drive a web browser one step at a time.
        \(AgentPrompts.nextAction)
        \(AgentPrompts.target)
        Reply with ONLY a JSON object: {"operation": "<a key of operations>", "target": "<a key of targets[operation]>"}.
        Use "target": null when the operation has no targets.
        """
        let started = Date()
        let raw = try await complete(LLMRequest(prompt: state.jsonString(), systemPrompt: system))
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        let invalid = AgentError.invalidResponse("The model returned no valid step; no action executed.")
        guard let json = Self.jsonObject(in: raw), let operation = json["operation"]?.stringValue,
              space.operations[operation] != nil else { throw invalid }
        var target: String?
        if let candidates = space.targets[operation] {
            guard let t = json["target"]?.stringValue, candidates[t] != nil else { throw invalid }
            target = t
        }
        guard let choice = space.actionID(operation: operation, target: target) else { throw invalid }
        return AgentDecision(choice: choice, operation: operation, target: target, confidence: nil,
                             probability: nil, latencyMs: latency, model: modelName)
    }

    /// The first `{…}` object in a reply, tolerating code fences and prose.
    static func jsonObject(in raw: String) -> JSONValue? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw[start...end].utf8)),
              value.objectValue != nil else { return nil }
        return value
    }
}

/// Writes TYPE_TEXT values with the user's chat model (upstream uses a small LLM).
struct LLMFieldTextProvider: FieldTextProviding {
    var complete: (LLMRequest) async throws -> String = { try await LLMService.shared.complete($0) }

    func text(for context: JSONValue) async throws -> String {
        let raw = try await complete(LLMRequest(prompt: context.jsonString(), systemPrompt: AgentPrompts.textValue))
        guard let json = LLMPolicy.jsonObject(in: raw), json.objectValue?.keys.sorted() == ["text"],
              let value = json["text"]?.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 2000 else {
            throw AgentError.noText("The text helper returned no valid field value; nothing typed.")
        }
        return value
    }
}
