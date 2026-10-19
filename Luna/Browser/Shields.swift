import AppKit
import Combine
import Foundation

/// Brave-style Shields. Ads and trackers are blocked by the bundled uBlock Origin Lite (its
/// declarativeNetRequest rulesets, run by WKWebExtension); Shields sets uBOL's per-site filtering
/// mode through `UBOLBridge`. HTTPS upgrades and script blocking are Luna's own.
enum ShieldsLevel: String, Codable, CaseIterable, Identifiable {
    case standard, aggressive, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .aggressive: return "Aggressive"
        case .off: return "Off"
        }
    }

    /// uBOL filtering mode: none (0), optimal (2), complete (3).
    var uBOLMode: Int {
        switch self {
        case .off: return 0
        case .standard: return 2
        case .aggressive: return 3
        }
    }
}

/// One site's overrides; nil follows the global default.
struct ShieldsSite: Codable, Equatable {
    var up: Bool?
    var level: ShieldsLevel?
    var httpsUpgrade: Bool?
    var blockScripts: Bool?
}

/// What Shields does on a site. Shields down turns everything off.
struct ShieldsPolicy: Equatable {
    var up = true
    var level = ShieldsLevel.standard
    var httpsUpgrade = true
    var blockScripts = false

    var effectiveLevel: ShieldsLevel { up ? level : .off }
    var upgradesHTTPS: Bool { up && httpsUpgrade }
    var blocksScripts: Bool { up && blockScripts }
}

/// Global defaults (Settings → Privacy & Data → Shields). HTTPS reuses the existing HTTPS-first setting.
enum ShieldsPrefs {
    static let level = "luna_shields_level"
    static let blockScripts = "luna_shields_block_scripts"

    static func defaults(_ d: UserDefaults = .standard) -> ShieldsPolicy {
        ShieldsPolicy(up: true,
                      level: d.string(forKey: level).flatMap(ShieldsLevel.init(rawValue:)) ?? .standard,
                      httpsUpgrade: PrivacyPrefs.isOn(PrivacyPrefs.httpsFirst, d),
                      blockScripts: d.bool(forKey: blockScripts))
    }
}

/// Per-profile Shields exceptions `[host: ShieldsSite]`, saved as `shields.json` in the profile folder.
/// A store with no file (private sessions, tests) keeps them in memory only, like SitePermissionStore.
@MainActor
final class ShieldsStore: ObservableObject {
    @Published private(set) var sites: [String: ShieldsSite] = [:]
    private let fileURL: URL?
    let defaults: UserDefaults

    init(fileURL: URL?, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: ShieldsSite].self, from: data) {
            sites = saved
        }
    }

    nonisolated deinit {}

    private static var stores: [UUID: ShieldsStore] = [:]

    static func forProfile(_ id: UUID) -> ShieldsStore {
        if let store = stores[id] { return store }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luna/Profiles/\(id.uuidString)", isDirectory: true)
        let store = ShieldsStore(fileURL: dir.appendingPathComponent("shields.json"))
        stores[id] = store
        return store
    }

    /// Shields apply to web pages only; Luna's own pages and files are left alone.
    static func host(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    func policy(host: String?) -> ShieldsPolicy {
        var p = ShieldsPrefs.defaults(defaults)
        guard let host = host?.lowercased(), let site = sites[host] else { return p }
        p.up = site.up ?? p.up
        p.level = site.level ?? p.level
        p.httpsUpgrade = site.httpsUpgrade ?? p.httpsUpgrade
        p.blockScripts = site.blockScripts ?? p.blockScripts
        return p
    }

    /// Values equal to the default are dropped, so the site follows later default changes.
    func update(host: String, _ change: (inout ShieldsPolicy) -> Void) {
        let host = host.lowercased()
        guard !host.isEmpty else { return }
        var p = policy(host: host)
        change(&p)
        let d = ShieldsPrefs.defaults(defaults)
        let site = ShieldsSite(up: p.up == d.up ? nil : p.up,
                               level: p.level == d.level ? nil : p.level,
                               httpsUpgrade: p.httpsUpgrade == d.httpsUpgrade ? nil : p.httpsUpgrade,
                               blockScripts: p.blockScripts == d.blockScripts ? nil : p.blockScripts)
        sites[host] = site == ShieldsSite() ? nil : site
        save()
    }

    func remove(host: String) {
        guard sites.removeValue(forKey: host.lowercased()) != nil else { return }
        save()
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(sites).write(to: fileURL, options: .atomic)
    }
}

/// "N trackers & ads blocked" since install, per profile. Fed from uBOL's per-tab badge count as it
/// changes; written to UserDefaults every `flushEvery` blocks and when Luna quits or goes to the
/// background, never per request. No key (private sessions) keeps the count in memory only.
@MainActor
final class ShieldsCounter: ObservableObject {
    @Published private(set) var total: Int
    private var lastByTab: [UUID: Int] = [:]
    private(set) var pending = 0
    private let key: String?
    private let defaults: UserDefaults
    let flushEvery: Int

    init(key: String?, defaults: UserDefaults = .standard, flushEvery: Int = 50) {
        self.key = key
        self.defaults = defaults
        self.flushEvery = flushEvery
        total = key.map { defaults.integer(forKey: $0) } ?? 0
        guard key != nil else { return }
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(flushNow), name: name, object: nil)
        }
    }

    nonisolated deinit {}

    private static var counters: [UUID: ShieldsCounter] = [:]

    static func forProfile(_ id: UUID) -> ShieldsCounter {
        if let c = counters[id] { return c }
        let c = ShieldsCounter(key: "luna_shields_blocked_total_\(id.uuidString)")
        counters[id] = c
        return c
    }

    /// A tab's badge count; it restarts at 0 on navigation, so a drop starts a new page.
    func observe(tab: UUID, count: Int) {
        let last = lastByTab[tab] ?? 0
        lastByTab[tab] = count
        let delta = count >= last ? count - last : count
        guard delta > 0 else { return }
        total += delta
        pending += delta
        if pending >= flushEvery { flush() }
    }

    func tabClosed(_ tab: UUID) { lastByTab.removeValue(forKey: tab) }

    @objc private func flushNow() { flush() }

    func flush() {
        guard pending > 0, let key else { return }
        defaults.set(total, forKey: key)
        pending = 0
    }
}
