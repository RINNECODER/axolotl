import SwiftUI

// Row content for the sidebar outline. These are display-only: the outline
// owns clicks, selection and menus. System fonts and colors throughout.

func displayTitle(for tab: Tab) -> String {
    if let custom = tab.customTitle, !custom.isEmpty { return custom }
    // WebKit titles an empty page "about:blank"; show that tab as "New Tab".
    if !tab.title.isEmpty, tab.title != "about:blank" { return tab.title }
    guard let url = tab.url, url.absoluteString != "about:blank" else { return "New Tab" }
    if url.scheme == "luma" { return url.host == "history" ? "History" : "AI Chat" }
    if url.isFileURL { return url.lastPathComponent }
    return url.host ?? url.absoluteString
}

struct TabIcon: View {
    let tab: Tab
    let faviconURL: URL?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let url = tab.url, url.scheme == "http" || url.scheme == "https" || url.isFileURL {
                FaviconView(url: url, faviconURL: faviconURL)
            } else if tab.url?.scheme == "luma" {
                Image(systemName: tab.url?.host == "history" ? "clock" : "sparkles")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: size * 0.75))
        .frame(width: size, height: size)
        .scaleEffect(size / 20) // FaviconView renders at 20pt
        .frame(width: size, height: size)
    }
}

struct SidebarTabRow: View {
    let tab: Tab
    let faviconURL: URL?
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                TabIcon(tab: tab, faviconURL: faviconURL)
                    .opacity(isLoading ? 0.35 : 1)
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 16, height: 16)
            Text(displayTitle(for: tab))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct SidebarFolderRow: View {
    let name: String
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "folder" : "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .frame(maxHeight: .infinity)
    }
}

/// A split shows each pane's icon, joined, with the focused pane's title.
struct SidebarSplitRow: View {
    let panes: [Tab]
    let faviconURLs: [UUID: URL]
    let focused: UUID?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(panes) { tab in
                    TabIcon(tab: tab, faviconURL: faviconURLs[tab.id], size: 14)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
            Text(panes.map(displayTitle(for:)).joined(separator: " · "))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
        .frame(maxHeight: .infinity)
    }
}

struct SidebarDividerRow: View {
    var body: some View {
        Divider().padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
    }
}

struct SidebarNewTabRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
            Text("New Tab")
                .font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .frame(maxHeight: .infinity)
    }
}
