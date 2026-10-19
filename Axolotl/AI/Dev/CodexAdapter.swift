import Foundation

/// Drives `codex app-server` (JSON-RPC 2.0 over NDJSON stdio).
///
/// Verified against codex-cli 0.162.0 (schemas from `codex app-server generate-json-schema`):
/// initialize → initialized → thread/start | thread/resume → turn/start; approvals arrive as
/// server requests (numeric ids starting at 0) and are answered with a response of the same id.
/// `decline` is accepted for commands even when `availableDecisions` does not list it.
@MainActor
final class CodexAdapter: CLIAdapterBase, AgentCLISession {
    /// `untrusted` | `on-request` | `never`. On-request asks when a command needs to leave the sandbox.
    var approvalPolicy = "on-request"
    /// `read-only` | `workspace-write` | `danger-full-access`.
    var sandbox = "workspace-write"
    /// Reasoning effort for each turn (`low`, `medium`, `high`), or nil for the user's default.
    var effort: String?
    /// False starts an ephemeral thread (not saved, cannot be resumed); used by tests.
    var persistSession = true

    private var mapper = CodexRPCMapper()
    private var nextID = 1
    private var model: String?
    private var pendingSends: [String] = []

    init(mcp: DevMCPAttachment?, resumeStore: AgentCLIResumeStore = AgentCLIResumeStore()) {
        super.init(kind: .codex, mcp: mcp, resumeStore: resumeStore)
    }

    static func arguments(mcp: DevMCPAttachment?) -> [String] {
        ["app-server"] + (mcp?.codexArguments ?? [])
    }

    func start(projectDir: URL, model: String?, resumeID: String?) async throws {
        self.model = model
        var env: [String: String] = [:]
        if let mcp { env[AxolotlMCPBridge.tokenEnvVar] = mcp.token }
        do {
            try launch(arguments: Self.arguments(mcp: mcp), projectDir: projectDir, extraEnvironment: env)
        } catch {
            didEnd()
            throw error
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        request("initialize", ["clientInfo": .object(["name": "axolotl", "title": "Axolotl", "version": .string(version)])])
        write(.object(["jsonrpc": "2.0", "method": "initialized"]))
        var params: [String: JSONValue] = ["cwd": .string(projectDir.path), "approvalPolicy": .string(approvalPolicy), "sandbox": .string(sandbox)]
        if let model, !model.isEmpty { params["model"] = .string(model) }
        if !persistSession { params["ephemeral"] = .bool(true) }
        if let resumeID, !resumeID.isEmpty {
            params["threadId"] = .string(resumeID)
            request("thread/resume", params)
        } else {
            request("thread/start", params)
        }
    }

    /// Queued until the thread exists, so the UI can send right after `start`.
    func send(_ text: String) throws {
        try requireRunning()
        guard let thread = mapper.threadID else { pendingSends.append(text); return }
        guard mapper.activeTurnID == nil, !mapper.turnStarting else { throw AgentCLIError.busy }
        startTurn(thread: thread, text: text)
    }

    func interrupt() {
        guard isRunning, let thread = mapper.threadID, let turn = mapper.activeTurnID else { return }
        request("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)])
    }

    func respond(approvalID: String, decision: CLIApprovalDecision) {
        guard let reply = mapper.approvalReply(approvalID: approvalID, decision: decision) else { return }
        write(reply)
    }

    override func handle(_ message: JSONValue) {
        let hadThread = mapper.threadID != nil
        apply(mapper.map(message))
        if !hadThread, let thread = mapper.threadID, !pendingSends.isEmpty {
            startTurn(thread: thread, text: pendingSends.removeFirst())
        } else if mapper.activeTurnID == nil, !mapper.turnStarting, let thread = mapper.threadID, !pendingSends.isEmpty {
            startTurn(thread: thread, text: pendingSends.removeFirst())
        }
    }

    override func didEnd() {
        mcp?.revoke()
    }

    private func startTurn(thread: String, text: String) {
        var params: [String: JSONValue] = ["threadId": .string(thread), "input": .array([.object(["type": "text", "text": .string(text)])])]
        if let effort { params["effort"] = .string(effort) }
        request("turn/start", params)
    }

    private func request(_ method: String, _ params: [String: JSONValue]) {
        let id = nextID
        nextID += 1
        mapper.expect(id: id, method: method)
        write(.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(params)]))
    }
}

/// Pure mapping from Codex app-server JSON-RPC traffic to `CLIEvent`s (tested with fixtures).
struct CodexRPCMapper {
    private(set) var threadID: String?
    private(set) var activeTurnID: String?
    /// A turn/start is in flight but the turn id is not known yet.
    private(set) var turnStarting = false
    private var expected: [Int: String] = [:]
    private var pendingApprovals: [String: (rpcID: JSONValue, method: String, params: JSONValue)] = [:]
    private var fileChangePaths: [String: String] = [:]
    private var streamedOutput: Set<String> = []
    private var usageTotal: (input: Int, output: Int) = (0, 0)
    private var usageAtTurnStart: (input: Int, output: Int) = (0, 0)
    private var sawTokenUsage = false

    static let unsupportedCode = -32601

    mutating func expect(id: Int, method: String) {
        expected[id] = method
        if method == "turn/start" { turnStarting = true }
    }

    mutating func map(_ message: JSONValue) -> CLIMapResult {
        let method = message["method"]?.stringValue
        let id = message["id"]
        if let method, let id { return serverRequest(method: method, id: id, params: message["params"] ?? .null) }
        if let method { return notification(method: method, params: message["params"] ?? .null) }
        if let id { return response(id: id, message: message) }
        return CLIMapResult()
    }

    // MARK: Responses to our requests

    private mutating func response(id: JSONValue, message: JSONValue) -> CLIMapResult {
        var out = CLIMapResult()
        guard let n = CLIText.int(id), let method = expected.removeValue(forKey: n) else { return out }
        if let error = message["error"] {
            let text = error["message"]?.stringValue ?? "Codex rejected \(method)."
            out.events.append(.error(Self.readableError(text)))
            if method == "turn/start" {
                turnStarting = false
                out.events.append(.turnDone(usage: nil, outcome: .failed(Self.readableError(text))))
            }
            return out
        }
        let result = message["result"]
        switch method {
        case "thread/start", "thread/resume":
            if let thread = result?["thread"]?["id"]?.stringValue {
                threadID = thread
                out.events.append(.sessionStarted(id: thread))
            }
        case "turn/start":
            if let turn = result?["turn"]?["id"]?.stringValue { beginTurn(turn) }
        default:
            break
        }
        return out
    }

    private mutating func beginTurn(_ turn: String) {
        if activeTurnID != turn { usageAtTurnStart = usageTotal }
        activeTurnID = turn
        turnStarting = false
    }

    // MARK: Notifications

    private mutating func notification(method: String, params: JSONValue) -> CLIMapResult {
        var out = CLIMapResult()
        switch method {
        case "turn/started":
            if let turn = params["turn"]?["id"]?.stringValue { beginTurn(turn) }
        case "item/agentMessage/delta":
            if let delta = params["delta"]?.stringValue { out.events.append(.textDelta(delta)) }
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            if let item = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue {
                streamedOutput.insert(item)
                out.events.append(.toolOutput(id: item, text: delta))
            }
        case "item/started":
            if let started = Self.toolStart(params["item"]) {
                if params["item"]?["type"]?.stringValue == "fileChange" { fileChangePaths[started.id] = started.summary }
                out.events.append(.toolStarted(id: started.id, name: started.name, summary: started.summary))
            }
        case "item/completed":
            guard let item = params["item"], let type = item["type"]?.stringValue, let itemID = item["id"]?.stringValue else { break }
            if type == "agentMessage" {
                out.events.append(.messageDone(item["text"]?.stringValue ?? ""))
            } else if Self.toolTypes.contains(type) {
                if !streamedOutput.contains(itemID), let text = Self.toolResultText(item), !text.isEmpty {
                    out.events.append(.toolOutput(id: itemID, text: text))
                }
                streamedOutput.remove(itemID)
                fileChangePaths[itemID] = nil
                let status = item["status"]?.stringValue ?? ""
                let exit = CLIText.int(item["exitCode"])
                out.events.append(.toolFinished(id: itemID, isError: status == "failed" || status == "declined" || (exit ?? 0) != 0))
            }
        case "thread/tokenUsage/updated":
            if let total = params["tokenUsage"]?["total"] {
                usageTotal = (CLIText.int(total["inputTokens"]) ?? 0, CLIText.int(total["outputTokens"]) ?? 0)
                sawTokenUsage = true
            }
        case "turn/completed":
            let turn = params["turn"]
            let outcome: CLITurnOutcome
            switch turn?["status"]?.stringValue {
            case "completed": outcome = .completed
            case "interrupted": outcome = .interrupted
            default: outcome = .failed(turn?["error"]?["message"]?.stringValue.map { Self.readableError($0) })
            }
            let usage = sawTokenUsage ? CLIUsage(inputTokens: usageTotal.input - usageAtTurnStart.input,
                                                 outputTokens: usageTotal.output - usageAtTurnStart.output, costUSD: nil) : nil
            usageAtTurnStart = usageTotal
            activeTurnID = nil
            turnStarting = false
            out.events.append(.turnDone(usage: usage, outcome: outcome))
        case "error":
            if params["willRetry"] != .bool(true), let text = params["error"]?["message"]?.stringValue {
                out.events.append(.error(Self.readableError(text)))
            }
        default:
            break
        }
        return out
    }

    static let toolTypes: Set<String> = ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch"]

    static func toolStart(_ item: JSONValue?) -> (id: String, name: String, summary: String)? {
        guard let item, let type = item["type"]?.stringValue, toolTypes.contains(type), let id = item["id"]?.stringValue else { return nil }
        switch type {
        case "commandExecution":
            return (id, "Shell", item["command"]?.stringValue ?? "")
        case "fileChange":
            let paths: [String]
            if case .array(let changes)? = item["changes"] { paths = changes.compactMap { $0["path"]?.stringValue } } else { paths = [] }
            return (id, "Edit", CLIText.clip(paths.joined(separator: ", "), 300))
        case "mcpToolCall":
            let name = [item["server"]?.stringValue, item["tool"]?.stringValue].compactMap { $0 }.joined(separator: "/")
            return (id, name, CLIText.summary(of: item["arguments"]))
        case "webSearch":
            return (id, "WebSearch", item["query"]?.stringValue ?? "")
        default:
            return (id, item["tool"]?.stringValue ?? type, CLIText.summary(of: item["arguments"]))
        }
    }

    static func toolResultText(_ item: JSONValue) -> String? {
        if let output = item["aggregatedOutput"]?.stringValue { return output }
        if let error = item["error"]?["message"]?.stringValue { return error }
        if let result = item["result"], result != .null { return CLIText.clip(result.jsonString(), 2000) }
        return nil
    }

    /// Codex wraps API errors as a JSON string; surface the inner message.
    static func readableError(_ text: String) -> String {
        guard let data = text.data(using: .utf8), let json = CLIText.parse(data),
              let inner = json["error"]?["message"]?.stringValue ?? json["message"]?.stringValue else { return text }
        return inner
    }

    // MARK: Server requests (approvals)

    static func approvalKind(method: String) -> CLIApprovalKind? {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval": return .command
        case "item/fileChange/requestApproval", "applyPatchApproval": return .fileChange
        case "item/permissions/requestApproval": return .permission
        case "mcpServer/elicitation/request": return .tool
        default: return nil
        }
    }

    static func approvalID(_ rpcID: JSONValue) -> String {
        if let n = CLIText.int(rpcID) { return String(n) }
        return rpcID.stringValue ?? rpcID.jsonString()
    }

    private mutating func serverRequest(method: String, id: JSONValue, params: JSONValue) -> CLIMapResult {
        var out = CLIMapResult()
        guard let kind = Self.approvalKind(method: method) else {
            out.replies.append(.object(["jsonrpc": "2.0", "id": id, "error": .object([
                "code": .number(Double(Self.unsupportedCode)), "message": .string("Axolotl does not support \(method)"),
            ])]))
            return out
        }
        let approvalID = Self.approvalID(id)
        pendingApprovals[approvalID] = (id, method, params)
        out.events.append(.approvalRequest(CLIApprovalRequest(
            id: approvalID, kind: kind, title: method, summary: summary(method: method, params: params), payload: params)))
        return out
    }

    private func summary(method: String, params: JSONValue) -> String {
        let reason = params["reason"]?.stringValue
        switch method {
        case "item/commandExecution/requestApproval":
            return CLIText.clip([params["command"]?.stringValue, reason].compactMap { $0 }.joined(separator: " — "), 300)
        case "execCommandApproval":
            if case .array(let parts)? = params["command"] { return CLIText.clip(parts.compactMap(\.stringValue).joined(separator: " "), 300) }
            return reason ?? ""
        case "item/fileChange/requestApproval":
            let paths = params["itemId"]?.stringValue.flatMap { fileChangePaths[$0] }
            return CLIText.clip([paths, reason, params["grantRoot"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "), 300)
        case "mcpServer/elicitation/request":
            return CLIText.clip(params["message"]?.stringValue ?? params["serverName"]?.stringValue ?? "", 300)
        default:
            return CLIText.clip(reason ?? CLIText.summary(of: params["permissions"]), 300)
        }
    }

    /// The JSON-RPC response for an approval, or nil for an unknown / already answered id.
    mutating func approvalReply(approvalID: String, decision: CLIApprovalDecision) -> JSONValue? {
        guard let pending = pendingApprovals.removeValue(forKey: approvalID) else { return nil }
        return .object(["jsonrpc": "2.0", "id": pending.rpcID,
                        "result": Self.decisionResult(method: pending.method, params: pending.params, decision: decision)])
    }

    static func decisionResult(method: String, params: JSONValue, decision: CLIApprovalDecision) -> JSONValue {
        switch method {
        case "item/permissions/requestApproval":
            switch decision {
            case .allow: return .object(["permissions": params["permissions"] ?? .object([:]), "scope": "turn"])
            case .allowForSession: return .object(["permissions": params["permissions"] ?? .object([:]), "scope": "session"])
            case .deny, .cancel: return .object(["permissions": .object([:])])
            }
        case "mcpServer/elicitation/request":
            switch decision {
            case .allow, .allowForSession: return .object(["action": "accept", "content": .object([:])])
            case .deny: return .object(["action": "decline"])
            case .cancel: return .object(["action": "cancel"])
            }
        case "execCommandApproval", "applyPatchApproval":
            let value: String
            switch decision {
            case .allow: value = "approved"
            case .allowForSession: value = "approved_for_session"
            case .deny: value = "denied"
            case .cancel: value = "abort"
            }
            return .object(["decision": .string(value)])
        default:
            let value: String
            switch decision {
            case .allow: value = "accept"
            case .allowForSession: value = "acceptForSession"
            case .deny: value = "decline"
            case .cancel: value = "cancel"
            }
            return .object(["decision": .string(value)])
        }
    }
}
