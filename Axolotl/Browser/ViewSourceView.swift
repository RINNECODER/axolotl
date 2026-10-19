import SwiftUI

/// axolotl://source?url=…: the page's HTML, read-only, monospaced with line numbers (Chrome's view-source:).
/// Shows the HTML captured from the tab; after a relaunch it re-requests the page.
struct ViewSourceView: View {
    let page: URL
    let tabId: UUID
    var isPrivate = false
    @State private var lines: [String]?

    var body: some View {
        Group {
            if let lines {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { i in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(i + 1)")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 52, alignment: .trailing)
                                Text(lines[i].isEmpty ? " " : lines[i])
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.vertical, 10)
                    .padding(.trailing, 16)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: tabId) { lines = await Self.source(of: page, tabId: tabId, isPrivate: isPrivate).components(separatedBy: "\n") }
    }

    private static func source(of page: URL, tabId: UUID, isPrivate: Bool) async -> String {
        if let html = ViewSourceStore.html[tabId] { return html.source }
        guard page.scheme == "http" || page.scheme == "https" else { return "" }
        let session = isPrivate ? PrivateBrowsing.urlSession : URLSession.shared
        guard let (data, _) = try? await session.data(from: page) else { return "Couldn't load \(page.absoluteString)" }
        return String(decoding: data, as: UTF8.self)
    }
}
