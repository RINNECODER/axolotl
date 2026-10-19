import AppKit
import SwiftUI

/// "Choose…" under Customize: tick exactly which bookmark folders, sign-ins, sites,
/// extensions or addresses come over. Unticked keys land in `model.excluded`.
struct ImportPickSheet: View {
    @ObservedObject var model: BrowserImportModel
    let type: ImportDataType
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var off: Set<String> { model.excluded[type] ?? [] }

    private var items: [ImportPickItem] {
        let all = model.preview?.items[type] ?? []
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q) }
    }

    private var folders: [ImportedBookmark.FolderRow] { ImportedBookmark.folderRows(model.preview?.bookmarks ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose \(type.title.lowercased())").font(.system(size: 15, weight: .semibold))
                if type != .bookmarks {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $search).textFieldStyle(.plain)
                    }
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsStyle.field))
                }
                HStack(spacing: 14) {
                    Button("Select All") { select(true) }.buttonStyle(.link)
                    Button("Select None") { select(false) }.buttonStyle(.link)
                    Spacer()
                    if let summary = model.pickSummary(type) {
                        Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.system(size: 12))
            }
            .padding(16)
            SettingsHairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.preview == nil {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(30)
                    } else if type == .bookmarks {
                        ForEach(Array(folders.enumerated()), id: \.offset) { _, row in folderRow(row) }
                    } else {
                        ForEach(items) { itemRow($0) }
                    }
                    if model.preview != nil, type == .bookmarks ? folders.isEmpty : items.isEmpty {
                        Text(search.isEmpty ? "Nothing found in this profile." : "No matches.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                    }
                }
                .padding(.vertical, 6)
            }
            SettingsHairline()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.settingsProminent)
            }
            .padding(12)
        }
        .frame(width: 440, height: 480)
        .background(SettingsStyle.card)
        .settingsControlStyles()
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { !off.contains(key) }, set: { on in
            if on { model.excluded[type, default: []].remove(key) } else { model.excluded[type, default: []].insert(key) }
        })
    }

    /// All/None act on what the search shows; for bookmarks, on the top level.
    private func select(_ on: Bool) {
        if type == .bookmarks {
            model.excluded[type] = on ? [] : Set(folders.filter { $0.depth == 0 }.map(\.key))
            return
        }
        let keys = items.filter { $0.unsupported == nil }.map(\.id)
        if on { model.excluded[type, default: []].subtract(keys) } else { model.excluded[type, default: []].formUnion(keys) }
    }

    private func folderRow(_ row: ImportedBookmark.FolderRow) -> some View {
        let inherited = ImportedBookmark.isInside(row.key, off)
        return HStack(spacing: 8) {
            Toggle(row.name, isOn: inherited ? .constant(false) : binding(row.key)).toggleStyle(.checkbox).labelsHidden()
                .disabled(inherited)
            Image(systemName: row.key == ImportedBookmark.barKey ? "star" : "folder").foregroundStyle(.secondary).frame(width: 16)
            Text(row.name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            Text(row.links.formatted()).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.leading, 16 + CGFloat(row.depth) * 20)
        .padding(.trailing, 16)
        .frame(height: 30)
        .opacity(inherited ? 0.5 : 1)
    }

    private func itemRow(_ item: ImportPickItem) -> some View {
        HStack(spacing: 10) {
            Toggle(item.title, isOn: item.unsupported == nil ? binding(item.id) : .constant(false))
                .toggleStyle(.checkbox).labelsHidden().disabled(item.unsupported != nil)
            icon(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13)).lineLimit(1)
                let detail = [item.subtitle, item.unsupported ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .opacity(item.unsupported == nil ? 1 : 0.5)
    }

    @ViewBuilder
    private func icon(_ item: ImportPickItem) -> some View {
        if let url = item.icon, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 18, height: 18)
        } else {
            let symbol: [ImportDataType: String] = [.passwords: "key", .cookies: "globe", .extensions: "puzzlepiece.extension",
                                                    .autofill: "house"]
            Image(systemName: symbol[type] ?? "circle").foregroundStyle(.secondary).frame(width: 18, height: 18)
        }
    }
}
