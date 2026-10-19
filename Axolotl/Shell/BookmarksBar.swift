import AppKit
import SwiftUI

/// A row of the profile's bookmarks above the page (Settings → Appearance → Bookmarks bar). Chrome's behavior:
/// folders open a dropdown, chips that don't fit go in a "»" menu, chips reorder by drag.
struct BookmarksBar: View {
    @ObservedObject var store: BookmarkStore
    /// URL, and whether to open it in a new tab (⌘-click or the context menu).
    let onOpen: (URL, Bool) -> Void
    var onAddCurrentPage: (() -> Void)?
    /// Chrome layout template: Chrome's bookmarks bar (apps button, chips, "All Bookmarks").
    var chromeStyle = false
    var onApps: (() -> Void)?
    /// Opens axolotl://bookmarks.
    var onManage: (() -> Void)?

    static let height: CGFloat = 28

    var body: some View {
        if chromeStyle {
            ChromeBookmarksBar(store: store, onOpen: onOpen, onApps: onApps, onManage: onManage)
        } else {
            axolotlBar
        }
    }

    private var axolotlBar: some View {
        HStack(spacing: 2) {
            if store.children(of: nil).isEmpty {
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
                Spacer(minLength: 0)
            } else {
                BookmarkBarRow(store: store, chrome: false, onOpen: onOpen)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(NonDraggableWindowView())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookmarks bar")
    }

    /// How many chips fit in `available` points; when not all do, room is kept for the "»" button.
    static func fittingCount(_ widths: [CGFloat], in available: CGFloat, spacing: CGFloat, overflowWidth: CGFloat) -> Int {
        let total = widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
        if total <= available { return widths.count }
        var used: CGFloat = 0
        var count = 0
        for width in widths {
            let next = used + width + (count > 0 ? spacing : 0)
            if next + spacing + overflowWidth > available { break }
            used = next
            count += 1
        }
        return count
    }
}

/// The bar's chips, cut to the width with the rest in "»".
private struct BookmarkBarRow: View {
    @ObservedObject var store: BookmarkStore
    let chrome: Bool
    let onOpen: (URL, Bool) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let items = store.children(of: nil)
        let spacing: CGFloat = chrome ? 4 : 2
        GeometryReader { geo in
            let count = BookmarksBar.fittingCount(items.map { BookmarkChip.width($0, chrome: chrome) }, in: geo.size.width,
                                                  spacing: spacing, overflowWidth: 28)
            HStack(spacing: spacing) {
                ForEach(items.prefix(count)) { item in
                    BookmarkChip(item: item, store: store, chrome: chrome, onOpen: onOpen)
                }
                if count < items.count {
                    AxolotlMenuButton(alignment: .trailing, minWidth: 220, help: "More bookmarks", debugID: "bookmarks.overflow",
                                   items: { BookmarkMenus.entries(Array(items.dropFirst(count)), store: store, onOpen: onOpen) }) { isOpen in
                        Image(systemName: "chevron.right.2")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(chrome ? ChromePalette.for(scheme).icon : .secondary)
                            .frame(width: 24, height: chrome ? 28 : 22)
                            .background(RoundedRectangle(cornerRadius: chrome ? 14 : 6, style: .continuous)
                                .fill(chrome ? ChromePalette.for(scheme).hover.opacity(isOpen ? 1 : 0) : Color.primary.opacity(isOpen ? 0.08 : 0)))
                            .contentShape(Rectangle())
                    }
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Dropped on the bar's empty end: to the end of the bar.
            .dropDestination(for: String.self) { values, _ in BookmarkMenus.drop(values, into: nil, before: nil, store: store) }
        }
    }
}

private struct BookmarkChip: View {
    let item: Bookmark
    @ObservedObject var store: BookmarkStore
    let chrome: Bool
    let onOpen: (URL, Bool) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    /// The chip's laid-out width, from its title (the bar decides what fits before laying out).
    static func width(_ item: Bookmark, chrome: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: chrome ? 12.25 : 11.5)
        let text = ceil((item.title as NSString).size(withAttributes: [.font: font]).width)
        return chrome ? 12 + 16 + 7 + min(text, 150) : 14 + 14 + 5 + min(text, 127)
    }

    var body: some View {
        Group {
            if item.isFolder {
                AxolotlMenuButton(minWidth: 220, debugID: "bookmarks.folder.\(item.title)",
                               items: { BookmarkMenus.entries(store.children(of: item.id), store: store, onOpen: onOpen) }) { isOpen in
                    label(highlighted: isOpen || isHovering)
                }
            } else {
                Button {
                    onOpen(item.url, NSEvent.modifierFlags.contains(.command))
                } label: {
                    label(highlighted: isHovering)
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { isHovering = $0 }
        .help(item.isFolder ? item.title : item.url.absoluteString)
        .axolotlContextMenu { BookmarkMenus.contextEntries(item, store: store, onOpen: onOpen) }
        .draggable(BookmarkMenus.dragPrefix + item.id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            // On a folder: into it (Chrome). On a bookmark: in front of it.
            item.isFolder ? BookmarkMenus.drop(values, into: item.id, before: nil, store: store)
                : BookmarkMenus.drop(values, into: item.parentId, before: item.id, store: store)
        }
        .accessibilityLabel(item.title)
    }

    @ViewBuilder
    private func label(highlighted: Bool) -> some View {
        let palette = ChromePalette.for(scheme)
        HStack(spacing: chrome ? 7 : 5) {
            if item.isFolder {
                Image(systemName: "folder")
                    .font(.system(size: chrome ? 13 : 11.5))
                    .foregroundStyle(chrome ? palette.icon : .secondary)
                    .frame(width: chrome ? 16 : 14, height: chrome ? 16 : 14)
            } else {
                FaviconView(url: item.url).frame(width: chrome ? 16 : 14, height: chrome ? 16 : 14)
            }
            Text(item.title)
                .font(.system(size: chrome ? 12.25 : 11.5))
                .foregroundStyle(chrome ? AnyShapeStyle(palette.inactiveTitle) : AnyShapeStyle(.primary.opacity(0.85)))
                .lineLimit(1)
                .frame(maxWidth: chrome ? 150 : 127, alignment: .leading)
                .fixedSize()
        }
        .padding(.horizontal, chrome ? 6 : 7)
        .frame(height: chrome ? 28 : 22)
        .background(
            RoundedRectangle(cornerRadius: chrome ? 14 : 6, style: .continuous)
                .fill(chrome ? AnyShapeStyle(palette.hover.opacity(highlighted ? 1 : 0))
                    : AnyShapeStyle(.quaternary.opacity(highlighted ? 1 : 0)))
        )
        .contentShape(Rectangle())
    }
}

/// Menus, context menus, drag and Edit… shared by the bar and the bookmark manager.
enum BookmarkMenus {
    /// Drag payload prefix, so a dropped chip is told apart from dropped text.
    static let dragPrefix = "axolotl-bookmark:"

    /// A folder's contents as menu rows; folders become submenus (Chrome's bar dropdowns).
    @MainActor
    static func entries(_ items: [Bookmark], store: BookmarkStore, onOpen: @escaping (URL, Bool) -> Void) -> [AxolotlMenuEntry] {
        if items.isEmpty { return [.button("(empty)", id: "bm.empty", enabled: false) {}] }
        return items.map { item in
            item.isFolder
                ? .submenu(item.title, icon: "folder", id: "bmf.\(item.id)",
                           entries(store.children(of: item.id), store: store, onOpen: onOpen))
                : .button(item.title, image: AxolotlMenuEntry.favicon(item.url), id: "bm.\(item.id)") { onOpen(item.url, false) }
        }
    }

    /// Right-click on a chip or a manager row.
    @MainActor
    static func contextEntries(_ item: Bookmark, store: BookmarkStore, onOpen: @escaping (URL, Bool) -> Void) -> [AxolotlMenuEntry] {
        var entries: [AxolotlMenuEntry] = []
        if !item.isFolder {
            entries += [
                .button("Open in New Tab", icon: "plus.square.on.square") { onOpen(item.url, true) },
                .divider("b1"),
            ]
        }
        entries += [
            .button(item.isFolder ? "Rename…" : "Edit…", icon: "pencil") { edit(item, store: store) },
            .button("Delete", icon: "trash", destructive: true) { store.remove(item.id) },
            .divider("b2"),
            .button("Add Folder…", icon: "folder.badge.plus") {
                if let name = TextPrompt.name(title: "New Folder", initial: "New folder", confirm: "Add") {
                    store.addFolder(name, in: item.isFolder ? item.id : item.parentId)
                }
            },
        ]
        return entries
    }

    /// Moves the dragged bookmark (a `dragPrefix` payload); false for anything else.
    @MainActor
    static func drop(_ values: [String], into parent: UUID?, before sibling: UUID?, store: BookmarkStore) -> Bool {
        guard let value = values.first, value.hasPrefix(dragPrefix),
              let id = UUID(uuidString: String(value.dropFirst(dragPrefix.count))) else { return false }
        store.move(id, to: parent, before: sibling)
        return true
    }

    /// Edit…: title, and URL for a bookmark.
    @MainActor
    static func edit(_ item: Bookmark, store: BookmarkStore) {
        let alert = NSAlert()
        alert.messageText = item.isFolder ? "Rename Folder" : "Edit Bookmark"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let title = NSTextField(string: item.title)
        title.placeholderString = "Name"
        let url = NSTextField(string: item.url.absoluteString)
        url.placeholderString = "URL"
        let stack = NSStackView(views: item.isFolder ? [title] : [title, url])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: item.isFolder ? 24 : 56)
        for field in [title, url] { field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = title
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.update(item.id, title: title.stringValue, url: item.isFolder ? nil : parseURL(url.stringValue))
    }

    /// A typed URL; "example.com" gets https://. Nil when empty or unparseable (the old URL stays).
    static func parseURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        return URL(string: text.contains(":") ? text : "https://" + text)
    }
}

/// Chrome's bookmarks bar: 34 pt on the toolbar color, apps button and separator, 16 pt favicons with
/// 13 pt titles, "All Bookmarks" at the trailing edge, and the 1 pt line above the page.
private struct ChromeBookmarksBar: View {
    @ObservedObject var store: BookmarkStore
    let onOpen: (URL, Bool) -> Void
    var onApps: (() -> Void)?
    var onManage: (() -> Void)?
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
            BookmarkBarRow(store: store, chrome: true, onOpen: onOpen)
            Spacer(minLength: 8)
            Rectangle().fill(palette.bookmarkSeparator).frame(width: 1, height: 16).padding(.trailing, 6)
            AxolotlMenuButton(alignment: .trailing, minWidth: 240, debugID: "bookmarks.all", items: {
                var entries = BookmarkMenus.entries(store.children(of: BookmarkStore.otherBookmarksId), store: store, onOpen: onOpen)
                if let onManage {
                    entries += [.divider("all"), .button("Bookmark Manager", icon: "book", shortcut: "⌥⌘B", action: onManage)]
                }
                return entries
            }) { isOpen in
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
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.hover.opacity(isOpen ? 1 : 0)))
                .contentShape(Rectangle())
            }
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
