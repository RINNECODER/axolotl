import XCTest
@testable import Axolotl

/// Provider setup: OpenRouter request/response, signed-in CLI detection, and the default provider.
final class ProviderSetupTests: XCTestCase {
    // MARK: OpenRouter

    func testOpenRouterModelListKeepsTextModelsSortedByName() {
        let fixture = #"""
        {"data":[
          {"id":"z-ai/glm","name":"Z.ai: GLM","architecture":{"output_modalities":["text"]}},
          {"id":"black-forest/flux","name":"FLUX","architecture":{"output_modalities":["image"]}},
          {"id":"typesafe/jev-router","name":"TypeSafe: Jev Router","architecture":{"output_modalities":["text"]}},
          {"id":"anthropic/claude","name":"Anthropic: Claude"},
          {"name":"no id"}
        ]}
        """#
        let models = OpenRouterClient.parseModels(Data(fixture.utf8))
        XCTAssertEqual(models.map(\.id), ["anthropic/claude", "typesafe/jev-router", "z-ai/glm"])
        XCTAssertEqual(models.first?.name, "Anthropic: Claude")
    }

    func testOpenRouterChatRequestIsOpenAICompatible() throws {
        let req = LLMRequest(prompt: "hi", systemPrompt: "sys")
        let request = try OpenRouterClient.chatRequest(model: "openai/gpt", request: req, apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(Set(request.allHTTPHeaderFields!.keys), ["Authorization", "Content-Type", "X-Title"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "openai/gpt")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = body["messages"] as? [[String: String]]
        XCTAssertEqual(messages ?? [], [["role": "system", "content": "sys"], ["role": "user", "content": "hi"]])
    }

    private func stream(_ events: [String]) async -> (String, Error?) {
        var text = ""
        let lines = AsyncStream<String> { c in events.forEach { c.yield($0) }; c.finish() }
        do { try await OpenRouterClient.consume(lines: lines, onToken: { text += $0 }); return (text, nil) } catch { return (text, error) }
    }

    func testOpenRouterStreamReadsDeltasUntilDone() async {
        let (text, error) = await stream([": OPENROUTER PROCESSING",
                                          #"data: {"choices":[{"delta":{"role":"assistant","content":"Hel"}}]}"#,
                                          #"data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#,
                                          "data: [DONE]"])
        XCTAssertEqual(text, "Hello")
        XCTAssertNil(error)
    }

    func testOpenRouterStreamErrorsAndTruncationAreReported() async {
        let (_, cut) = await stream([#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#])
        guard case .incomplete? = cut as? LLMError else { return XCTFail("got \(String(describing: cut))") }
        let (_, failed) = await stream([#"data: {"error":{"message":"No credits"}}"#])
        XCTAssertEqual(failed?.localizedDescription, "No credits")
    }

    // MARK: Signed-in CLIs

    func testDetectsOnlySupportedSignedInCLIs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("provider-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["codex", "claude", "gemini"] {
            let file = dir.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let found = await HarnessCatalog.scan(path: dir.path, environment: [:], overrides: [:]) { exe, args, _, _ in
            switch (URL(fileURLWithPath: exe).lastPathComponent, args.first) {
            case ("codex", "login"): return (0, "")
            case ("claude", "auth"): return (0, #"{"loggedIn": false}"#)
            default: return (0, "1.0.0")
            }
        }
        XCTAssertEqual(Set(found.map(\.id)), [.codex, .claudeCode, .gemini])
        XCTAssertEqual(CLIChatClient.signedIn(found), [.codexCLI])
    }

    func testCLIArgumentsDisableToolsAndKeepThePromptPositional() {
        let req = LLMRequest(prompt: "-x", systemPrompt: "sys")
        let claude = CLIChatClient.arguments(.claudeCode, model: "opus", request: req, outputFile: "/tmp/o")
        XCTAssertEqual(claude, ["-p", "--tools", "", "--no-session-persistence", "--system-prompt", "sys", "--model", "opus", "--", "-x"])
        let codex = CLIChatClient.arguments(.codex, model: "", request: req, outputFile: "/tmp/o")
        XCTAssertEqual(Array(codex.suffix(2)), ["--", "sys\n\n-x"])
        XCTAssertTrue(codex.contains("read-only"))
        XCTAssertEqual(codex[codex.firstIndex(of: "--output-last-message")! + 1], "/tmp/o")
        XCTAssertFalse(codex.contains("--model"))
    }

    // MARK: Defaults

    func testDefaultProviderIsOpenRouterButSavedChoicesAndImplicitGeminiStay() {
        XCTAssertEqual(AIProvider.resolved(saved: nil, hasGeminiKey: false), .openrouter)
        XCTAssertEqual(AIProvider.resolved(saved: nil, hasGeminiKey: true), .gemini)
        XCTAssertEqual(AIProvider.resolved(saved: "anthropic", hasGeminiKey: true), .anthropic)
        XCTAssertEqual(AIProvider.resolved(saved: "removed-provider", hasGeminiKey: false), .openrouter)
        XCTAssertEqual(AIProvider.apiProviders.first, .openrouter)
    }

    func testComputerUseFallsBackToJevRouterOnOpenRouter() {
        XCTAssertTrue(ComputerUseAgent.defaultPolicy(typesafeKey: "t", openRouterKey: "o") is JevPolicy)
        let viaOpenRouter = ComputerUseAgent.defaultPolicy(typesafeKey: nil, openRouterKey: "o") as? LLMPolicy
        XCTAssertEqual(viaOpenRouter?.modelName, OpenRouterClient.jevModel)
        let chat = ComputerUseAgent.defaultPolicy(typesafeKey: "", openRouterKey: nil) as? LLMPolicy
        XCTAssertNotNil(chat)
        XCTAssertNotEqual(chat?.modelName, OpenRouterClient.jevModel)
    }
}
