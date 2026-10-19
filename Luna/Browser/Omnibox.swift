import SwiftUI

/// One row of the Chrome-style suggestion dropdown (toolbar address bar and start page).
struct OmniboxRow: Equatable, Identifiable {
    enum Kind: Equatable {
        /// What was typed, as a URL ("url – Open").
        case typedURL(String, URL)
        /// What was typed, as a search ("query – Google Search").
        case typedSearch(String)
        /// History, bookmark or open tab.
        case page(AddressSuggestion)
        /// A phrase from the engine's suggest endpoint.
        case search(String)
        /// Start page only: ask Luna instead of searching.
        case chat(String)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .typedURL, .typedSearch: return "typed"
        case .page(let p): return "p-\(p.url.absoluteString)"
        case .search(let s): return "s-\(s)"
        case .chat: return "chat"
        }
    }

    /// What ↑/↓ previews in the field.
    var fieldText: String {
        switch kind {
        case .typedURL(let t, _), .typedSearch(let t), .search(let t), .chat(let t): return t
        case .page(let p): return p.url.absoluteString
        }
    }
}

/// Chrome omnibox rules, kept pure so they can be tested.
enum Omnibox {
    static let maxRows = 6
    static let rowHeight: CGFloat = 32

    /// Only while the user is typing non-empty text: not on focus, not after navigation.
    static func shouldShow(focused: Bool, edited: Bool, text: String) -> Bool {
        focused && edited && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Row 1 is what was typed; then (deduped) pages, then up to 3 search phrases; at most `maxRows`.
    /// Pages leave room for 2 phrases when there are any.
    static func rows(typed: String, pages: [AddressSuggestion], phrases: [String],
                     engine: SearchEngine? = nil, chat: Bool = false, maxRows: Int = maxRows) -> [OmniboxRow] {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = AddressInput.url(for: text, engine: engine) else { return [] }
        let isURL = url != SearchEngine.url(searching: text, engine: engine)
        var rows = [OmniboxRow(kind: isURL ? .typedURL(text, url) : .typedSearch(text))]
        if chat { rows.append(OmniboxRow(kind: .chat(text))) }

        var seenURLs: [URL] = isURL ? [url] : []
        let uniquePages = pages.filter { page in
            guard !seenURLs.contains(where: { BookmarkStore.same($0, page.url) }) else { return false }
            seenURLs.append(page.url)
            return true
        }
        var seenPhrases: Set<String> = [text.lowercased()]
        let uniquePhrases = phrases.filter {
            let p = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !p.isEmpty && seenPhrases.insert(p).inserted
        }
        let room = max(0, maxRows - rows.count)
        let pageCount = min(uniquePages.count, max(0, room - min(uniquePhrases.count, 2)))
        let phraseCount = min(uniquePhrases.count, 3, room - pageCount)
        rows += uniquePages.prefix(pageCount).map { OmniboxRow(kind: .page($0)) }
        rows += uniquePhrases.prefix(phraseCount).map { OmniboxRow(kind: .search($0)) }
        return rows
    }

    /// The text to complete inline after `typed` (shown selected), or nil. Completes to the first page whose
    /// host starts with the typed text (with or without "www."), or its path when "/" was typed. Never after
    /// a deletion (`typed` is a prefix of `previous`) or when the text has spaces.
    static func inlineCompletion(typed: String, previous: String, pages: [AddressSuggestion]) -> String? {
        let q = typed.lowercased()
        guard !q.isEmpty, !q.contains(" "), !previous.lowercased().hasPrefix(q) else { return nil }
        for page in pages {
            guard let host = page.url.host?.lowercased(), !host.isEmpty else { continue }
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            for h in [bare, host] {
                var candidate = h
                if q.contains("/") {
                    candidate += page.url.path
                    while candidate.hasSuffix("/") { candidate.removeLast() }
                }
                if candidate.hasPrefix(q), candidate.count > q.count { return String(candidate.dropFirst(q.count)) }
            }
        }
        return nil
    }

    /// Chrome bolds the typed match in page titles and the suggested remainder in search phrases.
    static func highlighted(_ text: String, query: String, boldMatch: Bool) -> AttributedString {
        var s = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return s }
        if boldMatch {
            if let r = text.range(of: q, options: .caseInsensitive), let ar = Range(r, in: s) {
                s[ar].inlinePresentationIntent = .stronglyEmphasized
            }
        } else if text.lowercased().hasPrefix(q.lowercased()) {
            if let ar = Range(text.index(text.startIndex, offsetBy: q.count)..<text.endIndex, in: s) {
                s[ar].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return s
    }

    /// "github.com/foo" for display: no scheme, no "www.", no trailing slash.
    static func displayURL(_ url: URL) -> String {
        var s = url.absoluteString
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// The dropdown: one surface hung under the field, compact 32 pt rows, accent selection.
struct OmniboxDropdown: View {
    let rows: [OmniboxRow]
    let query: String
    var selectedIndex: Int
    var engineTitle: String = SearchEngine.currentTitle
    /// False when the rows sit inside a card that already is the surface (start page).
    var drawsSurface = true
    let onSelect: (OmniboxRow) -> Void
    @State private var hovered: String?

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 12,
                                           bottomTrailingRadius: 12, topTrailingRadius: 6, style: .continuous)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                OmniboxRowView(row: row, query: query, engineTitle: engineTitle,
                               selected: index == selectedIndex, hovered: hovered == row.id,
                               onSelect: { onSelect(row) })
                    .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
            }
        }
        .padding(.vertical, 4)
        .background { if drawsSurface { LunaMaterialFill(shape: shape, surface: .menus) } }
        .clipShape(shape)
        .shadow(color: drawsSurface ? LunaSurface.shadow : .clear, radius: 8, y: 4)
    }
}

private struct OmniboxRowView: View {
    let row: OmniboxRow
    let query: String
    let engineTitle: String
    let selected: Bool
    let hovered: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                icon.frame(width: 16, height: 16)
                HStack(spacing: 0) {
                    Text(title).foregroundStyle(.primary).lineLimit(1).layoutPriority(1)
                    if let subtitle {
                        Text(" – " + Omnibox.highlighted(subtitle, query: query, boldMatch: isPage))
                            .foregroundStyle(LunaSurface.secondaryText).lineLimit(1)
                    }
                }
                .font(.system(size: 13))
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14)
            .frame(height: Omnibox.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? LunaSurface.accent.opacity(0.14) : (hovered ? LunaSurface.hover : .clear))
            .overlay(alignment: .leading) {
                if selected {
                    UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2)
                        .fill(LunaSurface.accent).frame(width: 3, height: 20)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var isPage: Bool { if case .page = row.kind { return true } else { return false } }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .page(let p):
            if case .history = p.kind {
                FaviconView(url: p.url).scaleEffect(0.8)
            } else {
                Image(systemName: p.symbol).font(.system(size: 12)).foregroundStyle(LunaSurface.secondaryText)
            }
        case .typedURL: Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(LunaSurface.secondaryText)
        case .chat: Image(systemName: "bubble.left").font(.system(size: 12)).foregroundStyle(LunaSurface.secondaryText)
        case .typedSearch, .search:
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(LunaSurface.secondaryText)
        }
    }

    private var title: AttributedString {
        switch row.kind {
        case .typedURL(let t, _), .typedSearch(let t), .chat(let t): return AttributedString(t)
        case .search(let s): return Omnibox.highlighted(s, query: query, boldMatch: false)
        case .page(let p):
            let url = Omnibox.displayURL(p.url)
            let name = p.display.isEmpty || p.display == p.url.host ? url : p.display
            return Omnibox.highlighted(name, query: query, boldMatch: true)
        }
    }

    private var subtitle: String? {
        switch row.kind {
        case .typedURL: return "Open"
        case .typedSearch(let t):
            return "\(CustomSearchEngine.keywordSearch(t, in: CustomSearchEngine.load())?.engine.name ?? engineTitle) Search"
        case .chat: return "Ask Luna"
        case .search: return nil
        case .page(let p):
            let url = Omnibox.displayURL(p.url)
            return p.display.isEmpty || p.display == p.url.host ? nil : url
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.kind {
        case .page(let p):
            if case .openTab = p.kind {
                Button(action: onSelect) {
                    Label("Switch to this tab", systemImage: "arrow.right.square")
                        .font(.system(size: 11, weight: .medium))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Capsule().fill(LunaSurface.hover))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LunaSurface.accent)
                .fixedSize()
            }
        case .chat: Text("⌘↩").font(.system(size: 11)).foregroundStyle(.tertiary)
        default: EmptyView()
        }
    }
}
