import Combine
import Foundation
import WebKit

/// A per-site permission, like Chrome's Site settings. WebKit on macOS has no delegate for
/// notifications (and device motion is iOS-only), so those aren't here.
enum SitePermission: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable {
    case camera, microphone, location, popups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .location: return "Location"
        case .popups: return "Pop-ups and redirects"
        }
    }

    /// The bubble line: "<host> wants to: Use your camera".
    var request: String {
        switch self {
        case .camera: return "Use your camera"
        case .microphone: return "Use your microphone"
        case .location: return "Know your location"
        case .popups: return "Open pop-ups"
        }
    }

    var icon: String {
        switch self {
        case .camera: return "video"
        case .microphone: return "mic"
        case .location: return "location"
        case .popups: return "macwindow.on.rectangle"
        }
    }

    /// Choices for this permission. Pop-ups never prompt: "block" means only pop-ups opened by a click.
    var choices: [SitePermissionDecision] { self == .popups ? [.allow, .block] : [.ask, .allow, .block] }

    /// Choices for the global default (Chrome: Ask or Don't allow; pop-ups: Allow or Don't allow).
    var defaultChoices: [SitePermissionDecision] { self == .popups ? [.allow, .block] : [.ask, .block] }

    var builtInDefault: SitePermissionDecision { self == .popups ? .block : .ask }

    /// UserDefaults key of the global default (registered in CustomizationRegistry as `sitePermissions.<raw>`).
    var defaultsKey: String { "luna_site_permission_default_\(rawValue)" }
    var registryKey: String { "sitePermissions.\(rawValue)" }

    /// The permissions a media-capture request asks for.
    static func forMedia(_ type: WKMediaCaptureType) -> [SitePermission] {
        switch type {
        case .camera: return [.camera]
        case .microphone: return [.microphone]
        case .cameraAndMicrophone: return [.camera, .microphone]
        @unknown default: return [.camera, .microphone]
        }
    }
}

enum SitePermissionDecision: String, Codable {
    case ask, allow, block

    func title(for permission: SitePermission) -> String {
        switch self {
        case .ask: return "Ask"
        case .allow: return "Allow"
        case .block: return "Block"
        }
    }

    /// One decision for a request covering several permissions: any block blocks, all allowed allows, else ask.
    static func combined(_ decisions: [SitePermissionDecision]) -> SitePermissionDecision {
        if decisions.contains(.block) { return .block }
        return decisions.allSatisfy { $0 == .allow } ? .allow : .ask
    }
}

/// One pending prompt. `respond` runs WebKit's decision handler exactly once.
@MainActor
final class SitePermissionRequest: Identifiable {
    let id = UUID()
    let host: String
    let permissions: [SitePermission]
    private var handler: ((_ allow: Bool, _ remember: Bool) -> Void)?

    init(host: String, permissions: [SitePermission], handler: @escaping (_ allow: Bool, _ remember: Bool) -> Void) {
        self.host = host
        self.permissions = permissions
        self.handler = handler
    }

    func respond(allow: Bool, remember: Bool) {
        let h = handler
        handler = nil
        h?(allow, remember)
    }
}

/// Per-profile site exceptions `[origin: [permission: decision]]` (origin = scheme://host[:port]), saved as
/// `site_permissions.json` in the profile folder. A bare host (old files, callers) means `https://host`. A store with no file (private sessions, tests) keeps decisions in memory only.
/// Hosts without an exception follow the global default for that permission.
@MainActor
final class SitePermissionStore: ObservableObject {
    @Published private(set) var sites: [String: [SitePermission: SitePermissionDecision]] = [:]
    private let fileURL: URL?
    private let defaults: UserDefaults

    init(fileURL: URL?, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: [SitePermission: SitePermissionDecision]].self, from: data) {
            // Files from before origins were keyed by host: those become https://host.
            sites = Dictionary(saved.compactMap { k, v in Self.key(k).map { ($0, v) } }) { a, b in a.merging(b) { x, _ in x } }
            if sites.keys.sorted() != saved.keys.sorted() { save() }
        }
    }

    // Avoid the MainActor isolated-deinit executor hop (swiftlang/swift#88036), as other stores do.
    nonisolated deinit {}

    private static var stores: [UUID: SitePermissionStore] = [:]

    static func forProfile(_ id: UUID) -> SitePermissionStore {
        if let store = stores[id] { return store }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luna/Profiles/\(id.uuidString)", isDirectory: true)
        let store = SitePermissionStore(fileURL: dir.appendingPathComponent("site_permissions.json"))
        stores[id] = store
        return store
    }

    #if DEBUG
    /// Screenshots: an in-memory store for this profile so its real exceptions are untouched.
    static func useSnapshotStore(for id: UUID, sites: [String: [SitePermission: SitePermissionDecision]]) {
        let store = SitePermissionStore(fileURL: nil)
        store.sites = Dictionary(uniqueKeysWithValues: sites.map { (key($0.key) ?? $0.key, $0.value) })
        stores[id] = store
    }
    #endif

    func defaultDecision(_ permission: SitePermission) -> SitePermissionDecision {
        defaults.string(forKey: permission.defaultsKey).flatMap(SitePermissionDecision.init(rawValue:))
            .flatMap { permission.defaultChoices.contains($0) ? $0 : nil } ?? permission.builtInDefault
    }

    func decision(_ permission: SitePermission, host: String?) -> SitePermissionDecision {
        guard let host = Self.key(host) else { return defaultDecision(permission) }
        return sites[host]?[permission] ?? defaultDecision(permission)
    }

    /// Setting the global default clears the exception, so the site follows later default changes.
    func set(_ decision: SitePermissionDecision, _ permission: SitePermission, host: String) {
        guard let host = Self.key(host) else { return }
        // Grants for origins anyone on the network can impersonate (plain http) aren't remembered.
        if decision == .allow, !Self.canRememberGrants(host) { return }
        var entry = sites[host] ?? [:]
        entry[permission] = decision == defaultDecision(permission) ? nil : decision
        sites[host] = entry.isEmpty ? nil : entry
        save()
    }

    func removeAll(host: String) {
        guard let host = Self.key(host), sites[host] != nil else { return }
        sites[host] = nil
        save()
    }

    /// The origin key: `scheme://host[:port]` (default ports dropped); a bare host means https.
    static func key(_ site: String?) -> String? {
        guard let site = site?.lowercased(), !site.isEmpty else { return nil }
        guard site.contains("://") else { return "https://" + site }
        return origin(URL(string: site)) ?? site
    }

    static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return origin(scheme: scheme, host: host, port: url.port ?? 0)
    }

    static func origin(_ o: WKSecurityOrigin) -> String {
        origin(scheme: o.protocol.lowercased(), host: o.host.lowercased(), port: o.port)
    }

    private static func origin(scheme: String, host: String, port: Int) -> String {
        let isDefault = port == 0 || (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(h)" + (isDefault ? "" : ":\(port)")
    }

    static func canRememberGrants(_ origin: String) -> Bool {
        guard let url = URL(string: origin) else { return false }
        return url.scheme == "https" || SiteSecurity.isLocal(url.host)
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(sites).write(to: fileURL, options: .atomic)
    }
}

enum SiteSecurity {
    /// Chrome's gray "Not secure" label: plain http, except this Mac (localhost / loopback).
    static func showsNotSecure(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "http", url.host != nil else { return false }
        return !isLocal(url.host)
    }

    /// localhost / loopback: this Mac.
    static func isLocal(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    /// The lock: an https page that loaded without error, with only secure subresources and a server trust.
    static func isSecure(_ url: URL, webView: WKWebView?, hasPageError: Bool) -> Bool {
        guard url.scheme?.lowercased() == "https", !hasPageError, let webView else { return false }
        return webView.hasOnlySecureContent && webView.serverTrust != nil
    }

    /// Issuer of the page's certificate (e.g. "WE1"), from the web view's server trust.
    static func certificateIssuer(_ webView: WKWebView?) -> String? {
        guard let trust = webView?.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], chain.count > 1 else { return nil }
        return SecCertificateCopySubjectSummary(chain[1]) as String?
    }

    /// Website data records (cookies, storage, cache) that belong to `host`; WebKit names them by registrable domain.
    static func records(_ records: [WKWebsiteDataRecord], for host: String) -> [WKWebsiteDataRecord] {
        let host = host.lowercased()
        return records.filter { host == $0.displayName.lowercased() || host.hasSuffix("." + $0.displayName.lowercased()) }
    }
}

/// Brave's "Forget me when I close this site": per profile, sites whose cookies and storage are removed
/// once their last open tab closes. Off for every site by default; never used in private windows.
enum ForgetSites {
    static func defaultsKey(_ profileId: UUID) -> String { "luna_forget_sites_\(profileId.uuidString)" }

    /// The stored form of a host: lowercased, without "www.".
    /// shortcut: not eTLD+1, so "mail.example.com" covers only itself and its subdomains; use a public-suffix list if that matters.
    static func site(_ host: String?) -> String? {
        guard var h = host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    static func sites(_ profileId: UUID, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey(profileId)) ?? []
    }

    static func isOn(host: String?, profileId: UUID, defaults: UserDefaults = .standard) -> Bool {
        site(host).map { sites(profileId, defaults: defaults).contains($0) } ?? false
    }

    static func set(_ on: Bool, host: String?, profileId: UUID, defaults: UserDefaults = .standard) {
        guard let site = site(host) else { return }
        var list = sites(profileId, defaults: defaults).filter { $0 != site }
        if on { list.append(site) }
        if list.isEmpty { defaults.removeObject(forKey: defaultsKey(profileId)) } else { defaults.set(list, forKey: defaultsKey(profileId)) }
    }

    private static func belongs(_ host: String, to site: String) -> Bool {
        let h = host.lowercased()
        return h == site || h.hasSuffix("." + site)
    }

    /// The site to forget after a tab on `host` closed: one marked to forget that no `openHosts` still uses.
    static func siteToForget(closing host: String?, openHosts: [String], sites: [String]) -> String? {
        guard let host, let site = sites.first(where: { belongs(host, to: $0) }),
              !openHosts.contains(where: { belongs($0, to: site) }) else { return nil }
        return site
    }

    /// Removes every website data record of `site` from `dataStore`.
    static func forget(_ site: String, in dataStore: WKWebsiteDataStore) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { records in
            let mine = SiteSecurity.records(records, for: site)
            if !mine.isEmpty { dataStore.removeData(ofTypes: types, for: mine) {} }
        }
    }
}
