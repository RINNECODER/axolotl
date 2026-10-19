import Foundation

/// Settings → Axolotl Max toggles. Features the user triggers are on by default;
/// ones that send data to the model automatically are opt-in.
enum AxolotlMaxPrefs {
    static let askOnPage = "axolotl_max_ask_on_page"
    static let linkPreviews = "axolotl_max_link_previews"
    static let tidyTitles = "axolotl_max_tidy_titles"
    static let tidyDownloads = "axolotl_max_tidy_downloads"

    static func isOn(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil { return key == askOnPage || key == linkPreviews }
        return defaults.bool(forKey: key)
    }
}

/// Axolotl Max: small AI helpers (Arc Max equivalent), all routed through the
/// model chosen in Settings → AI & Models.
enum AxolotlMax {

    // MARK: Ask on Page

    static func askOnPage(question: String, title: String?, url: URL?, pageText: String) async throws -> String {
        var context = ""
        if let url { context += "URL: \(url.absoluteString)\n" }
        if let title, !title.isEmpty { context += "Title: \(title)\n" }
        context += "Page content:\n\(pageText.prefix(16_000))"
        var req = LLMRequest(prompt: question, context: context)
        req.systemPrompt = "You answer questions about the web page the user is looking at, using only the page content provided. Be brief: one short paragraph or a few bullets. If the page doesn't contain the answer, say so. \(LLMClock.contextLine())"
        return try await LLMService.shared.complete(req)
    }

    // MARK: Link previews

    struct Preview {
        let title: String
        let summary: String
    }

    /// Fetches the linked page (public addresses only) and summarizes it.
    static func preview(of url: URL) async throws -> Preview {
        guard let source = await WebSearchService.fetchSingleURL(url), !source.content.isEmpty else {
            throw LLMError.stream("Couldn't load a preview of this link.")
        }
        var req = LLMRequest(prompt: "Summarize this page in 2-3 short bullet points. No preamble.",
                             context: "URL: \(url.absoluteString)\nTitle: \(source.title)\n\n\(source.content)")
        req.systemPrompt = "You write very short, factual link previews."
        return Preview(title: source.title, summary: try await LLMService.shared.complete(req))
    }

    // MARK: Tidy titles

    static func tidyTitle(for title: String, url: URL?) async throws -> String {
        var req = LLMRequest(prompt: """
            Shorten this browser tab title to 1-3 words that identify the page. Keep brand or product names. \
            Reply with only the new title.
            Title: \(title)
            Site: \(url?.host ?? "")
            """)
        req.systemPrompt = "You rename browser tabs with short, clean titles."
        return cleanTitle(try await LLMService.shared.complete(req), fallback: title)
    }

    /// Strips quotes/markup and caps length; falls back if the model rambles.
    static func cleanTitle(_ raw: String, fallback: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.components(separatedBy: .newlines).first ?? t
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*#.").union(.whitespaces))
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        guard !t.isEmpty, t.count <= 40 else { return fallback }
        return t
    }

    // MARK: Tidy downloads

    static func tidyFilename(for filename: String, sourceURL: URL?) async throws -> String {
        var req = LLMRequest(prompt: """
            Rename this downloaded file so it's easy to find later: short, descriptive, Title Case, \
            no dates unless meaningful, no extension. Reply with only the new name.
            File: \(filename)
            Downloaded from: \(sourceURL?.absoluteString ?? "unknown")
            """)
        req.systemPrompt = "You give downloaded files clean, descriptive names."
        return cleanFilename(try await LLMService.shared.complete(req), original: filename)
    }

    /// Keeps the original extension and removes characters Finder disallows.
    static func cleanFilename(_ raw: String, original: String) -> String {
        let ext = (original as NSString).pathExtension
        var base = cleanTitle(raw, fallback: (original as NSString).deletingPathExtension)
        if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) { base = String(base.dropLast(ext.count + 1)) }
        base = base.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if base.isEmpty { return original }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    // MARK: Tidy Today

    struct TabSummary {
        let id: UUID
        let title: String
        let host: String
    }

    struct Group: Equatable {
        let name: String
        let tabIds: [UUID]
    }

    /// Proposes folders for Today tabs. Groups with fewer than two tabs are dropped.
    static func tidyGroups(for tabs: [TabSummary]) async throws -> [Group] {
        guard tabs.count >= 3 else { return [] }
        let list = tabs.enumerated().map { "\($0.offset): \($0.element.title) (\($0.element.host))" }.joined(separator: "\n")
        var req = LLMRequest(prompt: """
            Group these browser tabs into a few folders by topic or task. Leave tabs that don't fit out. \
            Reply with only JSON: [{"name": "Folder name", "tabs": [indexes]}]. Folder names are 1-3 words.
            Tabs:
            \(list)
            """)
        req.systemPrompt = "You organize browser tabs. You reply with JSON only."
        return parseGroups(try await LLMService.shared.complete(req), tabs: tabs)
    }

    /// Parses the model's JSON (tolerating code fences and prose around it).
    static func parseGroups(_ raw: String, tabs: [TabSummary]) -> [Group] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var used = Set<Int>()
        var groups: [Group] = []
        for item in array {
            guard let name = item["name"] as? String else { continue }
            let indexes = (item["tabs"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int(($0 as? String) ?? "") }
            let valid = indexes.filter { tabs.indices.contains($0) && used.insert($0).inserted }
            guard valid.count >= 2 else { valid.forEach { used.remove($0) }; continue }
            groups.append(Group(name: cleanTitle(name, fallback: "Folder"), tabIds: valid.map { tabs[$0].id }))
        }
        return groups
    }
}
