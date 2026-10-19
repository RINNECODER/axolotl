import SwiftUI
import UniformTypeIdentifiers

// Shared pieces for the AI panel and the AI start page: header buttons,
// capsule context chips, and the add-context popover. Chat styling lives
// in ChatStyle.swift.

// MARK: - Buttons

/// Circular icon button with the system hover fill (panel header).
struct PanelIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.quaternary.opacity(hovering ? 1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Context chips

/// What a chip represents; drives its icon.
enum ContextChipKind {
    case page(url: URL?, faviconURL: URL?)
    case tab(url: URL?, faviconURL: URL?)
    case document(filename: String)
}

/// Compact capsule for a piece of context (page, tab, or file). × on hover.
struct ContextChip: View {
    let kind: ContextChipKind
    let title: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            icon
                .frame(width: 13, height: 13)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("Remove \(title)")
        }
        .foregroundStyle(hovering ? .primary : .secondary)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(Capsule().fill(.quaternary.opacity(hovering ? 1 : 0.7)))
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(title)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .page(let url, let favicon), .tab(let url, let favicon):
            if let url, url.scheme?.hasPrefix("http") == true {
                FaviconView(url: url, faviconURL: favicon).scaleEffect(13.0 / 20.0)
            } else {
                Image(systemName: "globe").font(.system(size: 10))
            }
        case .document(let filename):
            Image(systemName: Self.documentSymbol(for: filename)).font(.system(size: 10))
        }
    }

    static func documentSymbol(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "csv": return "tablecells"
        case "json", "xml", "html": return "chevron.left.forwardslash.chevron.right"
        case "md": return "text.alignleft"
        default: return "doc.text"
        }
    }
}

// MARK: - Add context popover

/// The composer's "+" menu: searchable open tabs (toggle to include) and
/// "Choose Files…". Files can also be dropped onto the panel.
struct AddContextPopover: View {
    struct TabItem: Identifiable {
        let id: UUID
        let title: String
        let url: URL?
        let faviconURL: URL?
    }

    let tabs: [TabItem]
    let included: Set<UUID>
    let onToggleTab: (UUID) -> Void
    let onChooseFiles: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [TabItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tabs }
        return tabs.filter { $0.title.lowercased().contains(q) || ($0.url?.host?.lowercased().contains(q) ?? false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search tabs", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.7)))

            Text("Open tabs")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 2)

            ScrollView {
                VStack(spacing: 1) {
                    if filtered.isEmpty {
                        Text(tabs.isEmpty ? "No other tabs open" : "No matching tabs")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    ForEach(filtered) { tab in
                        PopoverRow(isOn: included.contains(tab.id), action: { onToggleTab(tab.id) }) {
                            HStack(spacing: 8) {
                                Group {
                                    if let url = tab.url, url.scheme?.hasPrefix("http") == true {
                                        FaviconView(url: url, faviconURL: tab.faviconURL).scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "globe").foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 16, height: 16)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(tab.title).font(.system(size: 12)).lineLimit(1)
                                    if let host = tab.url?.host {
                                        Text(host).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 260)

            Divider().padding(.vertical, 2)

            PopoverRow(isOn: false, showsCheck: false, action: onChooseFiles) {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip").frame(width: 16)
                    Text("Choose Files…").font(.system(size: 12))
                    Spacer()
                    Text("PDF, text, Markdown, CSV").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .frame(width: 300)
        .onAppear { searchFocused = true }
    }
}

private struct PopoverRow<Content: View>: View {
    let isOn: Bool
    var showsCheck = true
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                content
                Spacer(minLength: 4)
                if showsCheck {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LunaSurface.accent)
                        .opacity(isOn ? 1 : 0)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(hovering ? 1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Drop target

/// Overlay shown while files are dragged over the panel.
struct FileDropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(.secondary)
            .background(LunaMaterialFill(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), surface: .aiPanel))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus").font(.system(size: 22, weight: .light))
                    Text("Drop to attach").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .allowsHitTesting(false)
    }
}
