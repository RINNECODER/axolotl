import Foundation

/// Drives `claude -p` over stream-json with host-answered permission prompts.
///
/// Verified against Claude Code 2.1.300:
/// - Permission prompts only reach stdin/stdout with `--permission-prompt-tool stdio`
///   (`--permission-prompts host` alone auto-denies with a `permission_denied` system event).
/// - `--permission-mode default` is not a valid choice; `manual` is the asking mode.
/// - Read-only commands (e.g. `echo hi`) are auto-allowed by Claude's own rules; no prompt.
/// - `--mcp-config` is additive: the user's own MCP servers still load (source "dynamic").
@MainActor
final class ClaudeCodeAdapter: CLIAdapterBase, AgentCLISession {
    /// Claude's asking mode. `acceptEdits` / `plan` are also valid.
    var permissionMode = "manual"
    /// False keeps the session off disk (no resume); used by tests.
    var persistSession = true
    private var mapper = ClaudeStreamMapper()
    private var mcpConfigFile: URL?
    private var requestCounter = 0

    init(mcp: DevMCPAttachment?, resumeStore: AgentCLIResumeStore = AgentCLIResumeStore()) {
        super.init(kind: .claudeCode, mcp: mcp, resumeStore: resumeStore)
    }

    static func arguments(model: String?, resumeID: String?, permissionMode: String, mcpConfig: URL?, persist: Bool = true) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--include-partial-messages", "--verbose",
                    "--permission-mode", permissionMode, "--permission-prompt-tool", "stdio"]
        if let model, !model.isEmpty { args += ["--model", model] }
        if let resumeID, !resumeID.isEmpty { args += ["--resume", resumeID] }
        if let mcpConfig { args += ["--mcp-config", mcpConfig.path] }
        if !persist { args.append("--no-session-persistence") }
        return args
    }

    func start(projectDir: URL, model: String?, resumeID: String?) async throws {
        if let mcp { mcpConfigFile = try mcp.writeClaudeConfig() }
        do {
            try launch(arguments: Self.arguments(model: model, resumeID: resumeID, permissionMode: permissionMode,
                                             mcpConfig: mcpConfigFile, persist: persistSession),
                       projectDir: projectDir)
        } catch {
            didEnd()
            throw error
        }
        write(controlRequest(["subtype": "initialize"]))
    }

    func send(_ text: String) throws {
        try requireRunning()
        write(ClaudeStreamMapper.userMessage(text))
    }

    func interrupt() {
        guard isRunning else { return }
        mapper.interruptRequested = true
        write(controlRequest(["subtype": "interrupt"]))
    }

    func respond(approvalID: String, decision: CLIApprovalDecision) {
        guard let reply = mapper.approvalReply(requestID: approvalID, decision: decision) else { return }
        write(reply)
    }

    override func handle(_ message: JSONValue) {
        apply(mapper.map(message))
    }

    override func didEnd() {
        if let mcpConfigFile { DevMCPAttachment.removeClaudeConfig(mcpConfigFile) }
        mcpConfigFile = nil
        mcp?.revoke()
    }

    private func controlRequest(_ request: [String: JSONValue]) -> JSONValue {
        requestCounter += 1
        return .object(["type": "control_request", "request_id": .string("axolotl-\(requestCounter)"), "request": .object(request)])
    }
}

/// Pure mapping from Claude Code stream-json records to `CLIEvent`s (tested with fixtures).
struct ClaudeStreamMapper {
    private(set) var announcedSession: String?
    private var pendingApprovals: [String: (input: JSONValue, suggestions: JSONValue?)] = [:]
    var interruptRequested = false

    static func userMessage(_ text: String) -> JSONValue {
        .object(["type": "user", "message": .object(["role": "user", "content": .string(text)])])
    }

    static func approvalKind(tool: String) -> CLIApprovalKind {
        switch tool {
        case "Bash", "BashOutput", "KillShell", "PowerShell": return .command
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return .fileChange
        default: return .tool
        }
    }

    mutating func map(_ message: JSONValue) -> CLIMapResult {
        var out = CLIMapResult()
        let type = message["type"]?.stringValue
        if let id = message["session_id"]?.stringValue, announcedSession != id, type == "system" || type == "result" || type == "assistant" || type == "stream_event" {
            announcedSession = id
            out.events.append(.sessionStarted(id: id))
        }
        let isSubagent = message["parent_tool_use_id"].map { $0 != .null } ?? false
        switch type {
        case "stream_event":
            guard !isSubagent, let event = message["event"], event["type"]?.stringValue == "content_block_delta",
                  event["delta"]?["type"]?.stringValue == "text_delta", let text = event["delta"]?["text"]?.stringValue else { break }
            out.events.append(.textDelta(text))
        case "assistant":
            guard case .array(let blocks)? = message["message"]?["content"] else { break }
            for block in blocks {
                switch block["type"]?.stringValue {
                case "text":
                    if !isSubagent, let text = block["text"]?.stringValue { out.events.append(.messageDone(text)) }
                case "tool_use":
                    let id = block["id"]?.stringValue ?? ""
                    let name = block["name"]?.stringValue ?? "tool"
                    out.events.append(.toolStarted(id: id, name: name, summary: CLIText.summary(of: block["input"])))
                default: break
                }
            }
        case "user":
            guard case .array(let blocks)? = message["message"]?["content"] else { break }
            for block in blocks where block["type"]?.stringValue == "tool_result" {
                let id = block["tool_use_id"]?.stringValue ?? ""
                let text = Self.resultText(block["content"])
                if !text.isEmpty { out.events.append(.toolOutput(id: id, text: text)) }
                out.events.append(.toolFinished(id: id, isError: block["is_error"] == .bool(true)))
            }
        case "control_request":
            let requestID = message["request_id"]?.stringValue ?? ""
            let request = message["request"]
            if request?["subtype"]?.stringValue == "can_use_tool" {
                let tool = request?["tool_name"]?.stringValue ?? "tool"
                let input = request?["input"] ?? .object([:])
                pendingApprovals[requestID] = (input, request?["permission_suggestions"])
                out.events.append(.approvalRequest(CLIApprovalRequest(
                    id: requestID, kind: Self.approvalKind(tool: tool), title: tool,
                    summary: CLIText.summary(of: input), payload: request ?? .null)))
            } else {
                // Hooks, MCP-over-control and the like are not offered; answer so Claude does not wait.
                out.replies.append(.object(["type": "control_response", "response": .object([
                    "subtype": "error", "request_id": .string(requestID),
                    "error": .string("Axolotl does not handle \(request?["subtype"]?.stringValue ?? "this request")"),
                ])]))
            }
        case "control_response":
            if message["response"]?["subtype"]?.stringValue == "error" {
                out.events.append(.error(message["response"]?["error"]?.stringValue ?? "Claude Code rejected a control request."))
            }
        case "result":
            out.events.append(.turnDone(usage: Self.usage(message), outcome: outcome(message)))
            interruptRequested = false
        default:
            break
        }
        return out
    }

    /// The control_response for an approval, or nil for an unknown / already answered id.
    mutating func approvalReply(requestID: String, decision: CLIApprovalDecision) -> JSONValue? {
        guard let pending = pendingApprovals.removeValue(forKey: requestID) else { return nil }
        var response: [String: JSONValue]
        switch decision {
        case .allow, .allowForSession:
            response = ["behavior": "allow", "updatedInput": pending.input]
            if decision == .allowForSession, let suggestions = pending.suggestions, suggestions != .null {
                response["updatedPermissions"] = suggestions
            }
        case .deny:
            response = ["behavior": "deny", "message": "The user declined this in Axolotl."]
        case .cancel:
            response = ["behavior": "deny", "message": "The user declined this in Axolotl and stopped the turn.", "interrupt": .bool(true)]
        }
        return .object(["type": "control_response", "response": .object([
            "subtype": "success", "request_id": .string(requestID), "response": .object(response),
        ])])
    }

    private func outcome(_ result: JSONValue) -> CLITurnOutcome {
        let subtype = result["subtype"]?.stringValue
        if subtype == "success", result["is_error"] != .bool(true) { return .completed }
        if interruptRequested || (result["terminal_reason"]?.stringValue ?? "").hasPrefix("aborted") { return .interrupted }
        if let text = result["result"]?.stringValue, !text.isEmpty { return .failed(text) }
        if case .array(let errors)? = result["errors"] {
            return .failed(errors.compactMap(\.stringValue).joined(separator: "\n"))
        }
        return .failed(subtype)
    }

    static func usage(_ result: JSONValue) -> CLIUsage? {
        guard let usage = result["usage"] else { return nil }
        let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .compactMap { CLIText.int(usage[$0]) }.reduce(0, +)
        return CLIUsage(inputTokens: input, outputTokens: CLIText.int(usage["output_tokens"]) ?? 0,
                        costUSD: result["total_cost_usd"]?.numberValue)
    }

    static func resultText(_ content: JSONValue?) -> String {
        switch content {
        case .string(let s)?: return s
        case .array(let parts)?: return parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default: return ""
        }
    }
}
