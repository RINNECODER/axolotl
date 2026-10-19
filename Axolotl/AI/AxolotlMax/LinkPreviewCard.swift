import SwiftUI

/// Floating summary of a Shift-hovered link (Arc's "5-second previews").
struct LinkPreviewCard: View {
    let url: URL
    let onOpen: () -> Void
    let onClose: () -> Void
    /// Private windows neither read nor fill the shared cache.
    var isPrivate = false

    @State private var preview: AxolotlMax.Preview?
    @State private var error: String?

    /// Summaries are cached per URL for the session.
    private static var cache: [URL: AxolotlMax.Preview] = [:]
    private static let cacheLimit = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FaviconView(url: url).scaleEffect(0.8).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preview?.title ?? url.host ?? url.absoluteString)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(url.host ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Open", action: onOpen)
                    .controlSize(.small)
                PanelIconButton(systemName: "xmark", help: "Close", action: onClose)
            }
            Divider()
            Group {
                if let preview {
                    RichMessageView(rawText: preview.summary, fontSize: 12.5, linkColor: AxolotlSurface.accent, onLinkTapped: { _ in })
                } else if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: 320)
        .background(AxolotlMaterialFill(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .task(id: url) {
            if !isPrivate, let hit = Self.cache[url] { preview = hit; return }
            do {
                let result = try await AxolotlMax.preview(of: url)
                if !isPrivate {
                    // shortcut: drops the whole cache at the cap, not LRU; fine for a hover cache.
                    if Self.cache.count >= Self.cacheLimit { Self.cache.removeAll() }
                    Self.cache[url] = result
                }
                if !Task.isCancelled { preview = result }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
