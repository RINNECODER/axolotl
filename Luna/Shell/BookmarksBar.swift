import SwiftUI

/// A row of the profile's bookmarks above the page (Settings → Appearance → Bookmarks bar).
struct BookmarksBar: View {
    @ObservedObject var store: BookmarkStore
    /// URL, and whether to open it in a new tab (⌘-click or the context menu).
    let onOpen: (URL, Bool) -> Void
    var onAddCurrentPage: (() -> Void)?
    /// Chrome layout template: Chrome's bookmarks bar (apps button, chips, "All Bookmarks").
    var chromeStyle = false
    var onApps: (() -> Void)?

    static let height: CGFloat = 28

    var body: some View {
        if chromeStyle {
            ChromeBookmarksBar(store: store, onOpen: onOpen, onApps: onApps)
        } else {
            lunaBar
        }
    }

    private var lunaBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if store.bookmarks.isEmpty {
                    Button {
                        onAddCurrentPage?()
                    } label: {
                        Label("Bookmark This Page", systemImage: "bookmark")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(onAddCurrentPage == nil)
                    .help("Add the current page to the bookmarks bar")
                }
                ForEach(store.bookmarks) { bookmark in
                    BookmarkChip(bookmark: bookmark, onOpen: onOpen, onRemove: { store.remove(bookmark.id) })
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: Self.height)
        .background(NonDraggableWindowView())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookmarks bar")
    }
}

private struct BookmarkChip: View {
    let bookmark: Bookmark
    let onOpen: (URL, Bool) -> Void
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            onOpen(bookmark.url, NSEvent.modifierFlags.contains(.command))
        } label: {
            HStack(spacing: 5) {
                FaviconView(url: bookmark.url)
                    .frame(width: 14, height: 14)
                Text(bookmark.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .frame(maxWidth: 160)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary.opacity(isHovering ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(bookmark.url.absoluteString)
        .contextMenu {
            Button("Open in New Tab") { onOpen(bookmark.url, true) }
            Divider()
            Button("Remove Bookmark", role: .destructive, action: onRemove)
        }
        .accessibilityLabel(bookmark.title)
    }
}

/// Chrome's bookmarks bar: 34 pt on the toolbar color, apps button and separator, 16 pt favicons with
/// 13 pt titles, "All Bookmarks" at the trailing edge, and the 1 pt line above the page.
private struct ChromeBookmarksBar: View {
    @ObservedObject var store: BookmarkStore
    let onOpen: (URL, Bool) -> Void
    var onApps: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ChromePalette.for(scheme)
        HStack(spacing: 0) {
            ChromeBookmarkButton(help: "Apps", action: { onApps?() }) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(palette.icon)
                    .frame(width: 20, height: 20)
            }
            Rectangle().fill(palette.bookmarkSeparator).frame(width: 1, height: 16).padding(.leading, 6).padding(.trailing, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.bookmarks) { bookmark in
                        ChromeBookmarkButton(help: bookmark.url.absoluteString, action: {
                            onOpen(bookmark.url, NSEvent.modifierFlags.contains(.command))
                        }) {
                            HStack(spacing: 7) {
                                FaviconView(url: bookmark.url).frame(width: 16, height: 16)
                                Text(bookmark.title)
                                    .font(.system(size: 12.25))
                                    .foregroundStyle(palette.inactiveTitle)
                                    .lineLimit(1)
                                    .frame(maxWidth: 150, alignment: .leading)
                                    .fixedSize()
                            }
                        }
                        .contextMenu {
                            Button("Open in New Tab") { onOpen(bookmark.url, true) }
                            Divider()
                            Button("Delete", role: .destructive) { store.remove(bookmark.id) }
                        }
                        .accessibilityLabel(bookmark.title)
                    }
                }
            }
            Spacer(minLength: 8)
            Rectangle().fill(palette.bookmarkSeparator).frame(width: 1, height: 16).padding(.trailing, 6)
            Menu {
                if store.bookmarks.isEmpty { Text("No bookmarks") }
                ForEach(store.bookmarks) { bookmark in
                    Button(bookmark.title) { onOpen(bookmark.url, false) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 13.5))
                        .foregroundStyle(palette.icon)
                    Text("All Bookmarks")
                        .font(.system(size: 12.25))
                        .foregroundStyle(palette.inactiveTitle)
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 28)
        .frame(height: ChromeMetrics.bookmarksBarHeight + 1, alignment: .top)
        .background(palette.toolbar)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.contentSeparator).frame(height: 1) }
        .background(NonDraggableWindowView())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookmarks bar")
    }
}

private struct ChromeBookmarkButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 6)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ChromePalette.for(scheme).hover.opacity(isHovering ? 1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
