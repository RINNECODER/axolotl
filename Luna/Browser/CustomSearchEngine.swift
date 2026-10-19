import Foundation

/// A search engine the user added in Settings → Search engine. "%s" in `template` becomes the query;
/// typing "`keyword` query" in the address bar searches this engine (Chrome's site search).
struct CustomSearchEngine: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var keyword: String
    var template: String

    static let defaultsKey = "luna_custom_search_engines"

    /// What `SearchEngine.defaultsKey` holds when this engine is the default.
    var selectionValue: String { "custom." + id.uuidString }

    /// An http(s) URL with a host and a "%s" for the query.
    static func isValidTemplate(_ template: String) -> Bool {
        guard template.contains("%s"),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: "q")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return false }
        return true
    }

    /// A keyword is one word (no whitespace).
    static func isValidKeyword(_ keyword: String) -> Bool {
        !keyword.isEmpty && !keyword.contains(where: \.isWhitespace)
    }

    func searchURL(for query: String) -> URL? {
        guard Self.isValidTemplate(template) else { return nil }
        // Encode everything but unreserved characters so "&", "#", "+" or "/" stay part of the query.
        let encoded = query.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// "yt cats" → (the engine with keyword "yt", "cats"); nil without a matching keyword and a query.
    static func keywordSearch(_ input: String, in engines: [CustomSearchEngine]) -> (engine: CustomSearchEngine, query: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !engines.isEmpty, let space = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
        let keyword = trimmed[..<space].lowercased()
        let query = trimmed[space...].trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let engine = engines.first(where: { $0.keyword.lowercased() == keyword }) else { return nil }
        return (engine, query)
    }

    static func load(_ defaults: UserDefaults = .standard) -> [CustomSearchEngine] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([CustomSearchEngine].self, from: data)) ?? []
    }

    static func save(_ engines: [CustomSearchEngine], _ defaults: UserDefaults = .standard) {
        if engines.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(engines) {
            defaults.set(data, forKey: defaultsKey)
        }
        // A removed default falls back to Google.
        if let raw = defaults.string(forKey: SearchEngine.defaultsKey), raw.hasPrefix("custom."),
           !engines.contains(where: { $0.selectionValue == raw }) {
            defaults.set(SearchEngine.google.rawValue, forKey: SearchEngine.defaultsKey)
        }
    }
}

extension SearchEngine {
    /// The custom engine chosen as the default, if any.
    static func selectedCustom(_ defaults: UserDefaults = .standard) -> CustomSearchEngine? {
        guard let raw = defaults.string(forKey: defaultsKey), raw.hasPrefix("custom.") else { return nil }
        return CustomSearchEngine.load(defaults).first { $0.selectionValue == raw }
    }

    /// The default engine's name, built-in or custom, for a stored selection.
    static func title(forSelection raw: String) -> String {
        SearchEngine(rawValue: raw)?.title
            ?? CustomSearchEngine.load().first { $0.selectionValue == raw }?.name
            ?? SearchEngine.google.title
    }

    static var currentTitle: String { selectedCustom()?.name ?? current.title }

    /// The engine to ask for suggestions; nil when a custom engine (no suggest endpoint) is the default,
    /// so typed text never goes to a provider the user did not choose.
    static var suggestEngine: SearchEngine? { selectedCustom() == nil ? current : nil }

    /// Where a search for `text` goes: a site-search keyword ("yt cats") first, then `engine`,
    /// else the default engine (built-in or custom).
    static func url(searching text: String, engine: SearchEngine? = nil, defaults: UserDefaults = .standard) -> URL? {
        let customs = CustomSearchEngine.load(defaults)
        if let hit = CustomSearchEngine.keywordSearch(text, in: customs) { return hit.engine.searchURL(for: hit.query) }
        if let engine { return engine.searchURL(for: text) }
        if let custom = selectedCustom(defaults), let url = custom.searchURL(for: text) { return url }
        return (defaults.string(forKey: defaultsKey).flatMap(SearchEngine.init(rawValue:)) ?? .google).searchURL(for: text)
    }
}
