// Axolotl — Query intent classifier for SmartSearch.
// Google first: anything that reads like a lookup goes to search. Input only
// goes to AI chat when it reads like a prompt (a task, constraints, reasoning,
// personal context). Clear cases are decided instantly by heuristics; the
// ambiguous middle is settled by the configured LLM, falling back to search.
import Foundation

enum QueryIntent: Equatable {
    case search
    case ai
}

enum QueryVerdict: Equatable {
    case search
    case ai
    /// Heuristics can't tell; ask the model (default to search).
    case unsure
}

struct QueryClassifier {

    private static let tlds: Set<String> = [
        "com", "org", "net", "edu", "gov", "io", "co", "app", "dev",
        "me", "tv", "ai", "xyz", "info", "biz", "us", "uk", "ca",
        "de", "fr", "jp", "au", "in", "br", "it", "nl", "ru", "ch"
    ]

    private static let navigationSites: Set<String> = [
        "youtube", "google", "gmail", "reddit", "twitter",
        "facebook", "instagram", "tiktok", "linkedin", "github",
        "netflix", "spotify", "amazon", "ebay", "wikipedia",
        "twitch", "discord", "slack", "notion", "figma",
        "stackoverflow", "hacker news", "craigslist", "yelp",
        "maps", "drive", "docs", "outlook", "yahoo", "bing",
        "chatgpt", "claude", "pinterest", "tumblr", "whatsapp",
        "telegram", "x.com", "threads"
    ]

    private static let searchTriggers: [String] = [
        "near me", "price of", "cost of", "how much is",
        "hours of", "address of", "phone number",
        "weather in", "weather for", "weather tomorrow", "weather today",
        "flights to", "flights from", "hotels in",
        "scores today", "scores last night", "scores yesterday",
        "stock price", "stock market",
        "recipe for", "calories in",
        "release date", "where to buy",
        "best restaurants", "best pizza", "best coffee",
        "directions to", "map of",
        "download", "login", "log in", "sign in", "sign up",
        "calculator", "online", "statistics", "tips", "news", "reviews", "tutorial",
    ]

    /// Verbs that turn input into a task for an assistant.
    private static let taskVerbs: Set<String> = [
        "write", "draft", "compose", "summarize", "summarise", "explain", "rewrite",
        "refactor", "translate", "calculate", "compute", "analyze", "analyse",
        "synthesize", "synthesise", "brainstorm", "outline", "review", "debug",
        "generate", "create", "plan", "suggest", "recommend", "edit", "proofread",
        "polish", "improve", "extract", "critique", "describe", "teach", "help",
        "walk", "imagine", "pretend", "act", "roleplay", "design", "fix",
        "simplify", "paraphrase", "reword", "evaluate", "argue", "persuade",
    ]

    /// Phrases that put constraints on an answer — prompt-shaped, not search-shaped.
    private static let constraintPhrases: [String] = [
        "step-by-step", "step by step", " words", "paragraph", "bullet", "exactly",
        "do not ", "don't ", "make sure", "ensure", "persona", "tone", "analogy",
        "in the style of", "pros and cons", "json", "as if", "for me", "walk me through",
        "break down", "eli5", "like i'm", "like im", "give me", "tell me", "show me",
        "help me", "can you", "could you", "would you", "please",
    ]

    private static let firstPerson: Set<String> = ["i", "me", "my", "our", "we", "us", "i'm", "im", "i've", "mine"]

    /// Instant classification for UI hints: `.ai` only when confident.
    static func classify(_ query: String) -> QueryIntent {
        verdict(query) == .ai ? .ai : .search
    }

    /// Heuristic score → verdict. Positive = prompt-like, negative = lookup-like.
    static func verdict(_ query: String) -> QueryVerdict {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = lower.split(whereSeparator: { $0 == " " || $0 == "\n" }).map {
            String($0).trimmingCharacters(in: .punctuationCharacters)
        }
        guard !words.isEmpty else { return .search }

        // URLs and known destinations always search.
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") { return .search }
        if !lower.contains(" "), lower.contains("."),
           let tld = lower.components(separatedBy: ".").last?.components(separatedBy: "/").first,
           tlds.contains(tld) { return .search }
        if navigationSites.contains(lower) { return .search }

        var score: Double = 0
        let n = words.count

        // Length: prompts are long, lookups are short.
        if n >= 12 { score += 2 }
        if n >= 22 { score += 2 }
        if n <= 3 { score -= 2.5 }

        // Task verbs (strongest when the input starts with one).
        let hasVerb = words.contains { taskVerbs.contains($0) }
        if let first = words.first, taskVerbs.contains(first) {
            // "convert python 2 print" style keyword strings aren't caught here;
            // a leading task verb with an object reads as an instruction.
            score += n >= 2 ? 3 : 0
        } else if hasVerb {
            score += 1.5
        }

        if words.contains(where: { firstPerson.contains($0) }) { score += 1 }
        let constraintHits = constraintPhrases.filter { lower.contains($0) }.count
        score += min(3, Double(constraintHits) * 1.5)

        // Multiple sentences, code, or structured data.
        let sentenceBreaks = lower.components(separatedBy: ". ").count - 1
            + lower.components(separatedBy: "? ").count - 1
        if sentenceBreaks >= 1 { score += 1.5 }
        if lower.contains("\n") || lower.contains("```") || lower.contains("{") || lower.contains("=>") { score += 2 }
        let numbers = words.filter { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "$%,"))) != nil }.count
        if numbers >= 3 { score += 1 }

        // Lookup signals.
        if searchTriggers.contains(where: { lower.contains($0) }) { score -= n <= 8 ? 2.5 : 1 }
        if !hasVerb && n <= 6 && !words.contains(where: { firstPerson.contains($0) }) { score -= 1.5 }

        if score >= 3 { return .ai }
        if score <= 0 { return .search }
        return .unsure
    }

    // MARK: - Model tie-break

    private static var modelCache: [String: QueryIntent] = [:]

    /// Final routing decision for a submitted query. Asks the configured model
    /// only when heuristics are unsure; any failure or timeout means search.
    static func resolve(_ query: String, timeout: TimeInterval = 1.6) async -> QueryIntent {
        switch verdict(query) {
        case .search: return .search
        case .ai: return .ai
        case .unsure: break
        }
        let key = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = await MainActor.run(body: { modelCache[key] }) { return cached }

        let prompt = """
        Decide where a browser should send what the user typed into its address bar.
        SEARCH = a web search engine: keyword lookups, navigation, facts, definitions, news, prices, products, places, how-to lookups, anything a results page answers.
        AI = an AI assistant: tasks that need writing, rewriting, reasoning, calculation with the user's own numbers, personal advice, or answers shaped by constraints.
        When in doubt, answer SEARCH. Reply with exactly one word: SEARCH or AI.

        Input: \"\(query)\"
        """
        // Race the model against a timeout. The model task isn't cancelled on
        // timeout (cancelled streams never complete); its late answer still
        // lands in the cache for next time.
        let once = ResolveOnce()
        let answer: QueryIntent? = await withCheckedContinuation { cont in
            once.continuation = cont
            Task {
                let reply = try? await LLMService.shared.complete(
                    LLMRequest(prompt: prompt, systemPrompt: "You are a query router. Reply with one word.")
                )
                let upper = reply?.uppercased() ?? ""
                let intent: QueryIntent? = reply == nil ? nil
                    : (upper.contains("AI") && !upper.contains("SEARCH") ? .ai : .search)
                if let intent { await MainActor.run { modelCache[key] = intent } }
                once.finish(intent)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(nil) }
        }
        return answer ?? .search
    }
}

/// Resumes a continuation exactly once, from whichever side finishes first.
private final class ResolveOnce: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<QueryIntent?, Never>?

    func finish(_ value: QueryIntent?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}
