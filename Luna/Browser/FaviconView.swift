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

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if failed.contains(url) { return nil }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<NSImage?, Never> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
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
            image = await FaviconCache.shared.image(for: fav)
        }
    }
}
