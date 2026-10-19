import Foundation

/// Chrome's per-site zoom: one level per host, saved per profile as a small JSON map.
/// `fileURL` nil (private windows) keeps levels in memory only.
final class SiteZoomStore {
    private let fileURL: URL?
    private var levels: [String: Double] = [:]

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            levels = saved
        }
    }

    func zoom(for host: String) -> CGFloat {
        CGFloat(levels[host.lowercased()] ?? 1)
    }

    /// 100% removes the host, so the file only lists sites the user zoomed.
    func set(_ zoom: CGFloat, for host: String) {
        let key = host.lowercased()
        if abs(zoom - 1) < 0.001 { levels.removeValue(forKey: key) } else { levels[key] = Double(zoom) }
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(levels).write(to: fileURL, options: .atomic)
    }

    private static var byProfile: [UUID: SiteZoomStore] = [:]

    /// One store per profile, shared by its windows so they never overwrite each other.
    static func forProfile(_ id: UUID) -> SiteZoomStore {
        if let store = byProfile[id] { return store }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = SiteZoomStore(fileURL: base.appendingPathComponent("Luna/Profiles/\(id.uuidString)/zoom.json"))
        byProfile[id] = store
        return store
    }
}
