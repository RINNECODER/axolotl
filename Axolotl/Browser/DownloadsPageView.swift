import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Chrome's downloads page at axolotl://downloads: this profile's downloads (a private window shows only its
/// own), with search, Show in Finder, Open, Remove from list, Pause / Resume / Retry and Clear all.
struct DownloadsPageView: View {
    let profileId: UUID
    let isPrivate: Bool
    @ObservedObject var manager: DownloadManager = .shared
    @State var query = ""

    private var items: [DownloadItem] {
        manager.recentDownloads.filter { item in
            belongs(item) && (query.isEmpty
                || item.displayName.localizedCaseInsensitiveContains(query)
                || item.url.absoluteString.localizedCaseInsensitiveContains(query))
        }
    }

    private func belongs(_ item: DownloadItem) -> Bool { item.belongs(profileId: profileId, isPrivate: isPrivate) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Downloads").font(.system(size: 20, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search downloads", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(width: 240, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.7)))
                Button("Clear all") { manager.clearInactive(where: belongs) }
                    .disabled(!manager.recentDownloads.contains { belongs($0) && !$0.isActive && $0.state != .paused })
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            Divider()
            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "Files you download appear here" : "No search results found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { DownloadPageRow(item: $0, manager: manager) }
                    }
                    .frame(maxWidth: 680)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DownloadPageRow: View {
    let item: DownloadItem
    @ObservedObject var manager: DownloadManager

    private var fileExists: Bool { FileManager.default.fileExists(atPath: item.fileURL.path) }
    private var isGone: Bool { item.state == .finished && !fileExists }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                if item.state == .finished && fileExists {
                    Button(item.displayName) { manager.open(item) }
                        .buttonStyle(.link)
                        .lineLimit(1)
                } else {
                    Text(item.displayName).strikethrough(isGone || item.state == .cancelled).lineLimit(1)
                }
                Text(item.url.host ?? item.url.absoluteString)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if item.isActive || item.state == .paused {
                    ProgressView(value: item.fraction ?? 0).progressViewStyle(.linear).controlSize(.small)
                }
                Text(detail).font(.system(size: 11))
                    .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                HStack(spacing: 12) {
                    switch item.state {
                    case .downloading:
                        Button("Pause") { manager.pause(item.id) }
                        Button("Cancel") { manager.cancel(item.id) }
                    case .paused:
                        Button("Resume") { manager.resume(item.id) }
                        Button("Cancel") { manager.cancel(item.id) }
                    case .failed, .cancelled:
                        Button("Retry") { manager.resume(item.id) }
                    case .finished:
                        if fileExists { Button("Show in Finder") { manager.revealInFinder(item) } }
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { manager.removeItem(item) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove from list")
            .disabled(item.isActive)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.45)))
    }

    private var isFailure: Bool {
        if case .failed = item.state { return true }
        return false
    }

    private var detail: String {
        let date = item.date.formatted(date: .abbreviated, time: .shortened)
        let size = ByteCountFormatter.string(fromByteCount: max(item.bytesExpected, item.bytesReceived), countStyle: .file)
        switch item.state {
        case .downloading:
            let received = ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file)
            return item.bytesExpected > 0 ? "\(received) of \(size)" : received
        case .paused: return "Paused · \(ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file))"
        case .finished: return isGone ? "Deleted · \(date)" : (item.bytesReceived > 0 ? "\(size) · \(date)" : date)
        case .failed(let message): return "Failed – \(message)"
        case .cancelled: return "Cancelled · \(date)"
        }
    }

    private var icon: NSImage {
        if item.state == .finished, fileExists { return NSWorkspace.shared.icon(forFile: item.fileURL.path) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: item.fileURL.pathExtension) ?? .data)
    }
}
