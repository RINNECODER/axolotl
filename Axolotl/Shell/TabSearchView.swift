import SwiftUI

/// One row of tab search: an open tab, or a recently closed one.
struct TabSearchItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let url: URL?
    var isClosed = false

    var host: String { url?.host.map(SiteShortcut.normalizedHost) ?? "" }
}

enum TabSearch {
    /// Rows matching `query` (title or host), best first: substring matches, earlier is better, then
    /// in-order letter matches with fewer gaps. An empty query keeps every row in order.
    static func filter(_ items: [TabSearchItem], query: String) -> [TabSearchItem] {
        let q = query.lowercased().filter { !$0.isWhitespace }
        guard !q.isEmpty else { return items }
        return items.enumerated()
            .compactMap { i, item in score(item.title + " " + item.host, q).map { (item, $0, i) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    static func score(_ text: String, _ query: String) -> Int? {
        let t = text.lowercased()
        if let r = t.range(of: query) { return 10_000 - t.distance(from: t.startIndex, to: r.lowerBound) }
        var index = t.startIndex
        var gaps = 0
        for ch in query {
            guard let found = t[index...].firstIndex(of: ch) else { return nil }
            gaps += t.distance(from: index, to: found)
            index = t.index(after: found)
        }
        return 5_000 - gaps
    }
}

/// Chrome's tab search (⇧⌘A): filter open and recently closed tabs, ↑↓ and Return to switch, Esc to close.
struct TabSearchView: View {
    let openTabs: [TabSearchItem]
    let closedTabs: [TabSearchItem]
    let onSelect: (TabSearchItem) -> Void
    let onClose: (UUID) -> Void
    let onDismiss: () -> Void

    @State var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var openResults: [TabSearchItem] { TabSearch.filter(openTabs, query: query) }
    private var closedResults: [TabSearchItem] { TabSearch.filter(closedTabs, query: query) }
    private var results: [TabSearchItem] { openResults + closedResults }

    var body: some View {
        let open = openResults
        let closed = closedResults
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tabs", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { pick(selected) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onExitCommand(perform: onDismiss)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if open.isEmpty && closed.isEmpty {
                            Text("No tabs found").foregroundStyle(.secondary).padding(14)
                        }
                        if !open.isEmpty { section("Open tabs \u{00B7} \(open.count)") }
                        ForEach(Array(open.enumerated()), id: \.element.id) { i, item in row(item, index: i) }
                        if !closed.isEmpty { section("Recently closed") }
                        ForEach(Array(closed.enumerated()), id: \.element.id) { i, item in row(item, index: open.count + i) }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: selected) { _, new in
                    if results.indices.contains(new) { proxy.scrollTo(results[new].id) }
                }
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AxolotlSurface.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AxolotlSurface.stroke))
        .shadow(color: AxolotlSurface.shadow, radius: 16, y: 6)
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search tabs")
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func row(_ item: TabSearchItem, index: Int) -> some View {
        TabSearchRow(item: item, isSelected: index == selected, onPick: { pick(index) },
                     onClose: item.isClosed ? nil : { onClose(item.id) })
            .id(item.id)
    }

    private func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    private func pick(_ index: Int) {
        let all = results
        guard all.indices.contains(index) else { return }
        onSelect(all[index])
    }
}

private struct TabSearchRow: View {
    let item: TabSearchItem
    let isSelected: Bool
    let onPick: () -> Void
    let onClose: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPick) {
                HStack(spacing: 10) {
                    Group {
                        if let url = item.url { FaviconView(url: url) } else { Image(systemName: "globe") }
                    }
                    .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title.isEmpty ? "Untitled" : item.title)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        if !item.host.isEmpty {
                            Text(item.host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onClose, isHovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close tab")
                .accessibilityLabel("Close \(item.title)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color.primary.opacity(isSelected ? 0.09 : (isHovering ? 0.05 : 0)))
        .onHover { isHovering = $0 }
    }
}
