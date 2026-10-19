// Axolotl — start page site tiles: only the shortcuts the user adds.
import SwiftUI
import Combine

struct SiteShortcut: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
}

/// Start page tile settings (Settings → Appearance → Start page).
enum StartPagePrefs {
    static let showShortcuts = "axolotl_start_shortcuts_enabled"
}

/// The user's shortcuts, shared across start pages.
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    static let key = "axolotl_start_shortcuts"

    @Published private(set) var shortcuts: [SiteShortcut]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([SiteShortcut].self, from: data) {
            shortcuts = saved
        } else {
            shortcuts = []
        }
    }

    func add(_ s: SiteShortcut) { shortcuts.append(s); save() }
    func remove(_ id: UUID) { shortcuts.removeAll { $0.id == id }; save() }
    func removeAll() { shortcuts = []; save() }
    /// Replaces the whole list (Personalization: settings changes and their undo).
    func replaceAll(_ list: [SiteShortcut]) { shortcuts = list; save() }

    func update(_ s: SiteShortcut) {
        guard let i = shortcuts.firstIndex(where: { $0.id == s.id }) else { return }
        shortcuts[i] = s
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shortcuts) { defaults.set(data, forKey: Self.key) }
    }
}

extension SiteShortcut {
    /// Accepts "github.com" or a full http(s) URL; nil for anything else (javascript:, file:, …).
    nonisolated static func siteURL(from text: String) -> URL? {
        let raw = text.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.contains(" ") else { return nil }
        guard let u = URL(string: raw.contains("://") ? raw : "https://\(raw)"),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, host.contains(".") else { return nil }
        return u
    }

    nonisolated static func normalizedHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "mail.google.com" → "Mail", "github.com" → "GitHub"-ish ("Github").
    nonisolated static func displayName(forHost host: String) -> String {
        let parts = normalizedHost(host).split(separator: ".")
        let label = parts.count > 2 ? parts[parts.count - 3] : (parts.first ?? Substring(host))
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}

// MARK: - View

struct StartShortcutsRow: View {
    let onOpen: (URL) -> Void

    @ObservedObject private var store = ShortcutStore.shared
    @State private var addingShortcut = false
    @State private var editing: SiteShortcut?

    private static let tileWidth: CGFloat = 76

    var body: some View {
        // Wraps onto more rows so every shortcut stays reachable.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileWidth, maximum: Self.tileWidth), spacing: 0)], spacing: 4) {
            ForEach(store.shortcuts) { s in
                tile(s)
            }
            addTile
        }
        .frame(maxWidth: .infinity)
    }

    private func tile(_ s: SiteShortcut) -> some View {
        ShortcutTile(title: s.title, help: s.url.host ?? s.url.absoluteString, action: { onOpen(s.url) },
                     onRemove: { remove(s) }, removeHelp: "Remove shortcut") {
            FaviconView(url: s.url)
                .scaleEffect(1.15)
        }
        .axolotlContextMenu {
            [
                .button("Edit…", icon: "pencil") { editing = s },
                .button("Remove", icon: "trash", destructive: true) { remove(s) },
            ]
        }
    }

    private func remove(_ s: SiteShortcut) {
        withAnimation(.easeOut(duration: 0.15)) { store.remove(s.id) }
    }

    private var addTile: some View {
        ShortcutTile(title: "Add shortcut", help: "Add a shortcut", action: { addingShortcut = true }) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .axolotlPopover(isPresented: $addingShortcut, arrowEdge: .bottom) {
            ShortcutEditor(title: "Add Shortcut", confirm: "Add", initial: nil) { store.add($0) }
        }
        .axolotlPopover(item: $editing, arrowEdge: .bottom) { s in
            ShortcutEditor(title: "Edit Shortcut", confirm: "Save", initial: s) { store.update($0) }
        }
    }
}

/// Small Name + URL form for adding or editing a shortcut.
private struct ShortcutEditor: View {
    let title: String
    let confirm: String
    let initial: SiteShortcut?
    let onSave: (SiteShortcut) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlText = ""
    @FocusState private var focus: Field?

    private enum Field { case name, url }

    private var url: URL? { SiteShortcut.siteURL(from: urlText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $name)
                    .focused($focus, equals: .name)
                TextField("URL", text: $urlText, prompt: Text("example.com"))
                    .focused($focus, equals: .url)
                    .onSubmit(save)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            name = initial?.title ?? ""
            urlText = initial?.url.absoluteString ?? ""
            focus = .name
        }
    }

    private func save() {
        guard let url, let host = url.host else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let title = trimmed.isEmpty ? SiteShortcut.displayName(forHost: host) : trimmed
        var s = initial ?? SiteShortcut(title: title, url: url)
        s.title = title
        s.url = url
        onSave(s)
        dismiss()
    }
}

private struct ShortcutTile<Icon: View>: View {
    let title: String
    let help: String
    let action: () -> Void
    var onRemove: (() -> Void)? = nil
    var removeHelp: String = "Remove"
    @ViewBuilder let icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                icon()
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white.opacity(hovering ? 0.12 : 0.07))
                    )
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let onRemove, hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color(white: 0.28)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(removeHelp)
                .offset(x: -6, y: -5)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
