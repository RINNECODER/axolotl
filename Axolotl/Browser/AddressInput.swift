import Foundation

/// What the address bar does with typed text: open it as a URL or search for it.
enum AddressInput {
    /// Chrome-like: explicit schemes as typed; local hosts (localhost, *.local, private/loopback
    /// IPs) and any host:port open over http; other dotted hosts over https; the rest is a search.
    static func url(for input: String, engine: SearchEngine? = nil) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("axolotl://") || lower.hasPrefix("file://")
            || lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if !trimmed.contains(" ") {
            if let authority = Authority(trimmed) {
                if authority.port != nil || authority.isLocal { return URL(string: "http://" + trimmed) }
                if authority.isIPv6 { return URL(string: "https://" + trimmed) }
            }
            if trimmed.contains(".") { return URL(string: "https://" + trimmed) }
        }
        return SearchEngine.url(searching: trimmed, engine: engine)
    }

    /// The host and optional port at the start of typed text ("host[:port][/path…]").
    private struct Authority {
        let host: String
        let port: Int?
        let isIPv6: Bool

        init?(_ text: String) {
            let end = text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
            let authority = String(text[..<end])
            guard !authority.isEmpty, !authority.contains("@") else { return nil }
            var portText: Substring?
            if authority.hasPrefix("[") {
                guard let close = authority.firstIndex(of: "]") else { return nil }
                host = String(authority[authority.index(after: authority.startIndex)..<close]).lowercased()
                let rest = authority[authority.index(after: close)...]
                if !rest.isEmpty {
                    guard rest.hasPrefix(":") else { return nil }
                    portText = rest.dropFirst()
                }
                isIPv6 = true
                guard host.contains(":") else { return nil }
            } else {
                let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count <= 2, !parts[0].isEmpty else { return nil }
                host = parts[0].lowercased()
                if parts.count == 2 { portText = parts[1] }
                isIPv6 = false
            }
            if let portText {
                // "mailto:x" or "javascript:…" is not a host:port.
                guard (1...5).contains(portText.count), portText.allSatisfy(\.isASCII), let p = Int(portText),
                      (1...65535).contains(p) else { return nil }
                port = p
            } else {
                port = nil
            }
        }

        var isLocal: Bool {
            if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
            if isIPv6 { return Self.isLocalIPv6(host) }
            return Self.isLocalIPv4(host)
        }

        private static func isLocalIPv4(_ host: String) -> Bool {
            let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard octets.count == 4, octets.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) <= 255 }) else { return false }
            let a = octets[0]!, b = octets[1]!
            return a == 127 || a == 10 || a == 0
                || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168)
                || (a == 169 && b == 254)
        }

        private static func isLocalIPv6(_ host: String) -> Bool {
            let h = host.split(separator: "%").first.map(String.init) ?? host // drop a zone id
            if h == "::1" || h == "::" { return true }
            guard let first = h.split(separator: ":").first, let word = UInt16(first, radix: 16) else { return false }
            return (word & 0xFE00) == 0xFC00 // fc00::/7 unique local
                || (word & 0xFFC0) == 0xFE80 // fe80::/10 link local
        }
    }
}

/// One URL row in the address-bar dropdown.
struct AddressSuggestion: Equatable {
    enum Kind: Equatable {
        case history, bookmark
        /// Already open in another tab: choosing it switches there ("Switch to tab").
        case openTab(UUID)
    }

    let display: String
    let url: URL
    let kind: Kind

    /// The row's SF Symbol (address bar and start page).
    var symbol: String {
        switch kind {
        case .history: return "clock.arrow.circlepath"
        case .bookmark: return "star"
        case .openTab: return "square.on.square"
        }
    }
}

enum AddressSuggestions {
    /// Chrome-like URL rows for a query: bookmarks, then history, then other open tabs, one row
    /// per URL. A bookmark or history page that is open in another tab becomes "Switch to tab".
    static func merge(query: String,
                      bookmarks: [Bookmark],
                      history: [(display: String, url: URL)],
                      openTabs: [(id: UUID, title: String, url: URL)],
                      limit: Int = 6) -> [AddressSuggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        func matches(_ title: String, _ url: URL) -> Bool {
            title.lowercased().contains(q) || url.absoluteString.lowercased().contains(q)
        }
        func tab(for url: URL) -> UUID? { openTabs.first { BookmarkStore.same($0.url, url) }?.id }

        var rows: [AddressSuggestion] = []
        func add(_ display: String, _ url: URL, _ kind: AddressSuggestion.Kind) {
            guard rows.count < limit, !rows.contains(where: { BookmarkStore.same($0.url, url) }) else { return }
            rows.append(AddressSuggestion(display: display, url: url, kind: tab(for: url).map { .openTab($0) } ?? kind))
        }
        for b in bookmarks where matches(b.title, b.url) { add(b.title, b.url, .bookmark) }
        for h in history { add(h.display, h.url, .history) }
        for t in openTabs where matches(t.title, t.url) { add(t.title.isEmpty ? (t.url.host ?? t.url.absoluteString) : t.title, t.url, .openTab(t.id)) }
        return rows
    }
}
