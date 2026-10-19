// Luma MVP - Favicon for tabs and history
import SwiftUI

/// Process-wide favicon cache. AsyncImage re-fetches on every view creation,
/// which hammers the network and janks the tab strip; this loader caches
/// decoded images in memory and deduplicates in-flight requests.
final class FaviconCache {
    static let shared = FaviconCache()

    private let cache = NSCache<NSURL, NSImage>()
    /// URLs that recently failed, so rows don't re-request a missing favicon on every render.
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    /// The bytes of a `data:` URI (base64 or percent-encoded), or nil for any other URL.
    nonisolated static func decodeDataURI(_ url: URL) -> Data? {
        let string = url.absoluteString
        guard string.count > 5, string.prefix(5).lowercased() == "data:",
              let comma = string.firstIndex(of: ",") else { return nil }
        let meta = string[string.index(string.startIndex, offsetBy: 5)..<comma].lowercased()
        let payload = String(string[string.index(after: comma)...])
        if meta.hasSuffix(";base64") {
            let b64 = (payload.removingPercentEncoding ?? payload).filter { !$0.isWhitespace }
            let padded = b64 + String(repeating: "=", count: (4 - b64.count % 4) % 4)
            return Data(base64Encoded: padded)
        }
        return (payload.removingPercentEncoding ?? payload).data(using: .utf8)
    }

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// `ephemeral`: a private window's fetch, kept out of the shared URL cache on disk.
    func image(for url: URL, ephemeral: Bool = false) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if failed.contains(url) { return nil }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<NSImage?, Never> {
            // <link rel=icon href="data:..."> carries the image inline; no request.
            if url.scheme?.lowercased() == "data" { return Self.decodeDataURI(url).flatMap(NSImage.init(data:)) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let session = ephemeral ? PrivateBrowsing.urlSession : URLSession.shared
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let image = NSImage(data: data) else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight.removeValue(forKey: url)
        if let image {
            // Cost estimate: 4 bytes per pixel of the largest representation.
            let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
            let cost = pixels > 0 ? pixels * 4 : Int(image.size.width * image.size.height) * 4
            cache.setObject(image, forKey: url as NSURL, cost: cost)
        } else {
            if failed.count > 1000 { failed.removeAll() }
            failed.insert(url)
        }
        return image
    }
}

/// Loads and displays a site favicon from URL (e.g. domain/favicon.ico).
/// If a specific favicon URL is provided (from page <link rel="icon">), uses that instead.
struct FaviconView: View {
    let url: URL
    let faviconURL: URL?

    @State private var image: NSImage?
    @Environment(\.isPrivateBrowsing) private var isPrivate

    init(url: URL, faviconURL: URL? = nil) {
        self.url = url
        self.faviconURL = faviconURL
    }

    private var effectiveFaviconURL: URL? {
        // Use provided favicon URL if available (e.g., from <link rel="icon">)
        if let faviconURL = faviconURL {
            return faviconURL
        }
        // Fallback to domain/favicon.ico
        guard let host = url.host, !host.isEmpty else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: effectiveFaviconURL) {
            guard let fav = effectiveFaviconURL else {
                image = nil
                return
            }
            // Synchronous cache hit avoids a placeholder flash on re-render.
            if let hit = FaviconCache.shared.cachedImage(for: fav) {
                image = hit
                return
            }
            image = await FaviconCache.shared.image(for: fav, ephemeral: isPrivate)
        }
    }
}
