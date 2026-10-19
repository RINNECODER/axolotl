import Foundation

/// Chat through a coding CLI the user already signed in to (`claude -p`, `codex exec`), so replies
/// use that CLI's plan. One process per reply, tools off / read-only, no saved session.
struct CLIChatClient {
    let harness: HarnessID
    var run: HarnessCommandRunner = HarnessCatalog.runCommand

    /// Installed CLIs Axolotl can chat through, from `HarnessCatalog`, and which are signed in
    /// (each CLI's own status command; credential files are never read).
    static func installed(_ found: [HarnessInfo]) -> [(provider: AIProvider, signedIn: Bool)] {
        AIProvider.allCases.compactMap { p in
            found.first { $0.id == p.harness && $0.supported }.map { (p, $0.signedIn == true) }
        }
    }

    /// One prompt for the CLI: earlier turns as a transcript, then the new message.
    static func prompt(_ req: LLMRequest) -> String {
        let turns = req.turns
        guard turns.count > 1 else { return turns.last?.text ?? req.userMessage }
        return turns.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n\n")
    }

    static func arguments(_ harness: HarnessID, model: String, request req: LLMRequest, outputFile: String) -> [String] {
        let modelArgs = model.isEmpty || model == "default" ? [] : ["--model", model]
        switch harness {
        case .claudeCode:
            // `--tools` takes a list, so it goes first; `--` keeps a prompt starting with "-" a prompt.
            return ["-p", "--tools", "", "--no-session-persistence", "--system-prompt", req.systemPrompt]
                + modelArgs + ["--", prompt(req)]
        default:
            return ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
                    "--output-last-message", outputFile] + modelArgs
                + ["--", "\(req.systemPrompt)\n\n\(prompt(req))"]
        }
    }

    func stream(model: String, request req: LLMRequest, onToken: @escaping (String) -> Void) async throws {
        guard let exe = await HarnessCatalog.shared.info(harness)?.executable else {
            throw LLMError.notConfigured("\(harness.displayName) isn't installed. Choose another provider in Settings → AI & Models.")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-cli-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        // shortcut: the reply arrives in one piece and a cancelled reply still runs to completion;
        // switch to AgentCLISession streaming if long replies need live tokens.
        guard let result = await run(exe, Self.arguments(harness, model: model, request: req, outputFile: out.path),
                                     LoginShellEnvironment.environment(), 300) else {
            throw LLMError.stream("\(harness.displayName) didn't answer in time.")
        }
        let text = (harness == .codex ? (try? String(contentsOf: out, encoding: .utf8)) : result.stdout)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard result.status == 0, !text.isEmpty else {
            throw LLMError.stream("\(harness.displayName) failed (exit \(result.status)). Check it's signed in: run it once in Terminal.")
        }
        onToken(text)
    }
}
