import Foundation
/// Routes parsed LLM responses to deterministic browser actions.
/// 
/// Per AGENTS.md: Model output is a proposal. The app decides what can happen.
/// This router performs deterministic mapping only; no LLM calls.
/// Per SRS F4: Actions are allowlisted and executed exactly once.
final class CommandRouter {
    // Avoid the MainActor isolated-deinit executor hop that double-frees
    // task-local storage on current macOS runtimes (swiftlang/swift#88036).
    nonisolated deinit {}

    /// Recognizes a deliberately small set of explicit browser commands locally.
    func proposal(for input: String, tabManager: TabManager) -> LLMResponse? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower == "close tab" || lower == "close current tab" || lower == "close the current tab" {
            return makeProposal(text: "Close the current tab?", type: .close_tab, payload: nil)
        }
        if let index = captureInteger(in: lower, pattern: #"^close tab (\d+)$"#) {
            return makeProposal(text: "Close tab \(index)?", type: .close_tab, payload: ["index": String(index)])
        }
        if let index = captureInteger(in: lower, pattern: #"^(?:switch|go) to tab (\d+)$"#) {
            return makeProposal(text: "Switch to tab \(index)?", type: .switch_tab, payload: ["index": String(index)])
        }

        let patterns: [(String, ActionType)] = [
            (#"^(?:open|visit) (.+?) in (?:a )?new tab$"#, .new_tab),
            (#"^new tab (?:for |with )?(.+)$"#, .new_tab),
            (#"^(?:navigate to|go to|visit) (.+)$"#, .navigate),
            (#"^open (.+)$"#, .navigate)
        ]
        for (pattern, type) in patterns {
            guard let destination = captureText(in: trimmed, pattern: pattern),
                  let url = resolveDestination(destination) else { continue }
            let verb = type == .new_tab ? "Open a new tab" : "Navigate this tab"
            return makeProposal(text: "\(verb) to \(url.absoluteString)?", type: type, payload: ["url": url.absoluteString])
        }
        return nil
    }
    
    /// Executes a browser action by mapping it to TabManager calls.
    /// Per AGENTS.md: Fail closed - if payload missing required fields, return error.
    /// Returns success message or error.
    func execute(action: BrowserAction, tabManager: TabManager) -> Result<String, Error> {
        switch action.type {
        case .new_tab:
            // new_tab requires a URL; normalize scheme if missing.
            guard let urlString = action.payload?["url"] else {
                return .failure(CommandRouterError.missingPayloadField("url"))
            }
            let normalizedString = normalizeURLString(urlString)
            guard let url = URL(string: normalizedString), isSafeBrowserURL(url) else {
                return .failure(CommandRouterError.invalidURL(urlString))
            }
            let tabId = tabManager.newTab(url: url)
            return .success("Created new tab: \(tabId.uuidString) -> \(normalizedString)")
            
        case .navigate:
            guard let urlString = action.payload?["url"] else {
                return .failure(CommandRouterError.missingPayloadField("url"))
            }
            let normalizedString = normalizeURLString(urlString)
            guard let url = URL(string: normalizedString), isSafeBrowserURL(url) else {
                return .failure(CommandRouterError.invalidURL(urlString))
            }
            tabManager.navigateCurrentTab(to: url)
            return .success("Navigated to: \(normalizedString)")
            
        case .switch_tab:
            guard let indexString = action.payload?["index"] else {
                return .failure(CommandRouterError.missingPayloadField("index"))
            }
            guard let index = Int(indexString), index >= 1, index <= tabManager.tabCount() else {
                return .failure(CommandRouterError.invalidIndex(indexString))
            }
            tabManager.switchToTab(index: index - 1)
            return .success("Switched to tab \(index)")
            
        case .close_tab:
            if let indexString = action.payload?["index"] {
                guard let index = Int(indexString), index >= 1, index <= tabManager.tabCount() else {
                    return .failure(CommandRouterError.invalidIndex(indexString))
                }
                let tabId = tabManager.tabOrder[index - 1]
                tabManager.closeTab(tabId)
                return .success("Closed tab \(index)")
            } else {
                // Close current tab if no index specified
                guard let currentId = tabManager.currentTab else {
                    return .failure(CommandRouterError.noCurrentTab)
                }
                tabManager.closeTab(currentId)
                return .success("Closed current tab: \(currentId.uuidString)")
            }
        }
    }
}

private extension CommandRouter {
    func makeProposal(text: String, type: ActionType, payload: [String: String]?) -> LLMResponse {
        LLMResponse(text: text, action: BrowserAction(id: UUID(), type: type, payload: payload))
    }

    func captureInteger(in input: String, pattern: String) -> Int? {
        captureText(in: input, pattern: pattern).flatMap(Int.init)
    }

    func captureText(in input: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: input) else { return nil }
        return String(input[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolveDestination(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let aliases = [
            "youtube": "youtube.com", "github": "github.com", "google": "google.com",
            "gmail": "mail.google.com", "reddit": "reddit.com", "wikipedia": "wikipedia.org"
        ]
        let candidate = aliases[value.lowercased()] ?? value
        if candidate.contains(" ") {
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: candidate)]
            return components?.url
        }
        let normalized = candidate.contains("://") ? candidate : "https://\(candidate)"
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else { return nil }
        return url
    }
}

/// Errors that can occur during action execution.
enum CommandRouterError: LocalizedError {
    case missingPayloadField(String)
    case invalidURL(String)
    case invalidTabID(String)
    case invalidIndex(String)
    case noCurrentTab
    case unsupportedOperation(String)
    
    var errorDescription: String? {
        switch self {
        case .missingPayloadField(let field):
            return "Missing required payload field: \(field)"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidTabID(let id):
            return "Invalid tab ID: \(id)"
        case .invalidIndex(let index):
            return "Invalid tab index: \(index)"
        case .noCurrentTab:
            return "No current tab to close"
        case .unsupportedOperation(let description):
            return "Unsupported operation: \(description)"
        }
    }
}

/// Normalizes a URL string by prefixing https:// if no scheme is present.
private func normalizeURLString(_ urlString: String) -> String {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed.contains("://") {
        return trimmed
    } else {
        return "https://" + trimmed
    }
}

// isSafeBrowserURL lives in AxolotlToolbox.swift, shared with the agent tools.
