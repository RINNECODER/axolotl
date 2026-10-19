// Luna — Downloads toolbar button and its popover.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Toolbar button that shows active download progress as a ring and opens the
/// downloads popover. The popover opens on its own when a download starts in
/// this window, the way Safari and Chrome surface new downloads.
struct DownloadsButton: View {
    @ObservedObject private var manager = DownloadManager.shared
    @State private var isPresented = false
    @State private var isHovering = false
    @State private var window: NSWindow?

    var body: some View {
        Button { isPresented.toggle() } label: {
            ZStack {
                if manager.hasActiveDownloads {
                    Circle()
                        .stroke(.quaternary, lineWidth: 2)
                        .frame(width: 18, height: 18)
                    if let fraction = manager.activeFraction {
                        Circle()
                            .trim(from: 0, to: max(0.03, fraction))
                            .stroke(LunaSurface.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 18, height: 18)
                            .animation(.linear(duration: 0.2), value: fraction)
                    } else {
                        IndeterminateRing()
                    }
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(LunaSurface.accent)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary.opacity(isHovering ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .accessibilityValue(accessibilityProgress)
        .background(WindowReader { window = $0 })
        .lunaPopover(isPresented: $isPresented, arrowEdge: .bottom) {
            DownloadsHubView(showAll: {
                isPresented = false
                BrowserCommandTargets.shared.keyOrFrontmost?.actions.showDownloads()
            })
        }
        .onChange(of: manager.presentRequest) { _, _ in
            // Only the window the user is working in shows the popover.
            if window?.isKeyWindow == true { isPresented = true }
        }
    }

    private var accessibilityProgress: String {
        guard manager.hasActiveDownloads else { return "" }
        if let fraction = manager.activeFraction { return "\(Int(fraction * 100)) percent" }
        return "Downloading"
    }
}

/// Spinning arc for downloads whose size the server didn't report.
private struct IndeterminateRing: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(LunaSurface.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

// MARK: - Popover

struct DownloadsHubView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @Environment(\.isPrivateBrowsing) private var isPrivate
    @Environment(\.browserProfileId) private var profileId
    private var items: [DownloadItem] { manager.recentDownloads.filter { $0.belongs(profileId: profileId, isPrivate: isPrivate) } }
    /// Opens luna://downloads (⇧⌘J).
    var showAll: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let showAll {
                    Button("Show All") { showAll() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                }
                if items.contains(where: { !$0.isActive }) {
                    Button("Clear") { manager.clearInactive { $0.belongs(profileId: profileId, isPrivate: isPrivate) } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No downloads")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            DownloadRow(item: item)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject private var manager = DownloadManager.shared
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(item.state == .finished ? 1 : 0.6)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.isActive {
                    ProgressView(value: item.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .opacity(item.fraction == nil ? 0.4 : 1)
                }
                HStack(spacing: 4) {
                    Text(status)
                    if item.originalFileURL != nil, !item.isTidying {
                        Button("Undo") { manager.undoTidy(item.id) }
                            .buttonStyle(.link)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isActive || item.state == .paused {
                if item.isActive {
                    iconButton("pause.circle.fill", help: "Pause") { manager.pause(item.id) }
                } else {
                    iconButton("play.circle.fill", help: "Resume") { manager.resume(item.id) }
                }
                iconButton("xmark.circle.fill", help: "Cancel") { manager.cancel(item.id) }
            } else {
                if item.retryPlan != nil {
                    iconButton("arrow.clockwise", help: "Retry") { manager.resume(item.id) }
                }
                if item.state == .finished {
                    if isHovering, item.originalFileURL == nil, !item.isTidying {
                        iconButton("sparkles", help: "Tidy file name") { manager.tidy(item.id) }
                    }
                    iconButton("magnifyingglass", help: "Show in Finder") { manager.revealInFinder(item) }
                }
                if isHovering {
                    iconButton("xmark", help: "Remove from list") { manager.removeItem(item) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(isHovering ? 0.6 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { if item.state == .finished { manager.open(item) } }
        .help(item.state == .finished ? "Double-click to open" : "")
    }

    private var icon: NSImage {
        if item.state == .finished, FileManager.default.fileExists(atPath: item.fileURL.path) {
            return NSWorkspace.shared.icon(forFile: item.fileURL.path)
        }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: item.fileURL.pathExtension) ?? .data)
    }

    private var isFailure: Bool {
        if case .failed = item.state { return true }
        return false
    }

    private var status: String {
        switch item.state {
        case .downloading, .paused:
            let received = ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file)
            let prefix = item.state == .paused ? "Paused · " : ""
            guard item.bytesExpected > 0 else { return prefix + received }
            return "\(prefix)\(received) of \(ByteCountFormatter.string(fromByteCount: item.bytesExpected, countStyle: .file))"
        case .finished:
            if item.isTidying { return "Tidying name…" }
            if let original = item.originalFileURL { return "Renamed from \(original.lastPathComponent)" }
            return item.date.formatted(date: .omitted, time: .shortened)
        case .failed(let message):
            return "Failed: \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
