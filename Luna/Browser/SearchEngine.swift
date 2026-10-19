import Foundation

/// The address bar's and start page's search engine (Settings → Search).
enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, brave, ecosia

    static let defaultsKey = "luna_search_engine"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .ecosia: return "Ecosia"
        }
    }

    private var base: String {
        switch self {
        case .google: return "https://www.google.com/search?q="
        case .duckduckgo: return "https://duckduckgo.com/?q="
        case .bing: return "https://www.bing.com/search?q="
        case .brave: return "https://search.brave.com/search?q="
        case .ecosia: return "https://www.ecosia.org/search?q="
        }
    }

    /// The engine's OpenSearch suggest endpoint (["query", ["phrase", …]]), or nil if it has none.
    func suggestURL(for query: String) -> URL? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        switch self {
        case .google: return URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)")
        case .duckduckgo: return URL(string: "https://ac.duckduckgo.com/ac/?q=\(q)&type=list")
        case .bing: return URL(string: "https://www.bing.com/osjson.aspx?query=\(q)")
        case .brave: return URL(string: "https://search.brave.com/api/suggest?q=\(q)")
        case .ecosia: return URL(string: "https://ac.ecosia.org/autocomplete?q=\(q)&type=list")
        }
    }

    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SearchEngine.init(rawValue:)) ?? .google
    }

    func searchURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: base + encoded)
    }

    /// Phrases from an OpenSearch suggest body (`["q", ["a", …]]`, optionally `window.…(…)`-wrapped); nil if unparseable.
    static func parseSuggestions(_ data: Data?) -> [String]? {
        guard let data, var raw = String(data: data, encoding: .utf8) else { return nil }
        if raw.hasPrefix("window."), let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]") {
            raw = String(raw[start...end])
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any],
              json.count >= 2, let items = json[1] as? [Any] else { return nil }
        return items.compactMap { item in
            if let s = item as? String { return s }
            return (item as? [Any])?.first as? String
        }
    }
}
