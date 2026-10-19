import SwiftUI

/// Chrome's bookmark manager at axolotl://bookmarks: folder tree on the left, the folder's contents (or search
/// results) on the right. Rename, edit, delete and new folder from the row menu; drag rows onto folders to move.
struct BookmarkManagerView: View {
    @ObservedObject var store: BookmarkStore
    /// URL, and whether to open it in a new tab.
    let onOpen: (URL, Bool) -> Void

    /// The folder shown on the right; nil is the bookmarks bar.
    @State var selection: UUID?
    @State var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                tree
                    .frame(width: 240)
                Divider()
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 16) {
            Label("Bookmarks", systemImage: "book")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search bookmarks", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 360, height: 30)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer()
            Button {
                if let name = TextPrompt.name(title: "New Folder", initial: "New folder", confirm: "Add") {
                    store.addFolder(name, in: selection)
                }
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    // MARK: Tree

    /// Folders depth-first under both roots.
    private var treeRows: [(id: UUID?, title: String, depth: Int)] {
        var rows: [(id: UUID?, title: String, depth: Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for folder in store.children(of: parent) where folder.isFolder {
                rows.append((folder.id, folder.title, depth))
                walk(folder.id, depth + 1)
            }
        }
        rows.append((nil, "Bookmarks bar", 0))
        walk(nil, 1)
        rows.append((BookmarkStore.otherBookmarksId, "Other bookmarks", 0))
        walk(BookmarkStore.otherBookmarksId, 1)
        return rows
    }

    private var tree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(treeRows, id: \.id) { row in
                    let selected = query.isEmpty && selection == row.id
                    Button {
                        query = ""
                        selection = row.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selected ? "folder.fill" : "folder")
                                .foregroundStyle(selected ? AxolotlSurface.accent : .secondary)
                            Text(row.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13))
                        .padding(.leading, 12 + CGFloat(row.depth) * 16)
                        .padding(.trailing, 8)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? AxolotlSurface.accent.opacity(0.15) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: String.self) { values, _ in
                        BookmarkMenus.drop(values, into: row.id, before: nil, store: store)
                    }
                    .accessibilityLabel(row.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(8)
        }
    }

    // MARK: List

    private var rows: [Bookmark] { query.isEmpty ? store.children(of: selection) : store.search(query) }

    private var list: some View {
        Group {
            if rows.isEmpty {
                Text(query.isEmpty ? "This folder is empty" : "No bookmarks match \u{201C}\(query)\u{201D}")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .dropDestination(for: String.self) { values, _ in
                        query.isEmpty && BookmarkMenus.drop(values, into: selection, before: nil, store: store)
                    }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { item in
                            BookmarkManagerRow(item: item, store: store, showsFolder: !query.isEmpty, onOpen: onOpen) {
                                selection = item.id
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct BookmarkManagerRow: View {
    let item: Bookmark
    @ObservedObject var store: BookmarkStore
    /// Search results name the folder each bookmark is in.
    let showsFolder: Bool
    let onOpen: (URL, Bool) -> Void
    let onOpenFolder: () -> Void
    @State private var isHovering = false

    private var folderName: String {
        guard let parent = item.parentId else { return "Bookmarks bar" }
        return parent == BookmarkStore.otherBookmarksId ? "Other bookmarks" : (store.item(parent)?.title ?? "")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if item.isFolder { onOpenFolder() } else { onOpen(item.url, NSEvent.modifierFlags.contains(.command)) }
            } label: {
                HStack(spacing: 12) {
                    if item.isFolder {
                        Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 16, height: 16)
                    } else {
                        FaviconView(url: item.url).frame(width: 16, height: 16)
                    }
                    Text(item.title).lineLimit(1)
                    if !item.isFolder {
                        Text(item.url.host ?? item.url.absoluteString)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if showsFolder {
                        Text(folderName).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            AxolotlMenuButton(alignment: .trailing, minWidth: 200, help: "More actions",
                           items: { BookmarkMenus.contextEntries(item, store: store, onOpen: onOpen) }) { _ in
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .opacity(isHovering ? 1 : 0.5)
            .accessibilityLabel("Actions for \(item.title)")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(isHovering ? 0.05 : 0)))
        .onHover { isHovering = $0 }
        .axolotlContextMenu { BookmarkMenus.contextEntries(item, store: store, onOpen: onOpen) }
        .draggable(BookmarkMenus.dragPrefix + item.id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            item.isFolder ? BookmarkMenus.drop(values, into: item.id, before: nil, store: store)
                : BookmarkMenus.drop(values, into: item.parentId, before: item.id, store: store)
        }
        .help(item.isFolder ? item.title : item.url.absoluteString)
    }
}
