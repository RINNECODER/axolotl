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

/// Per-profile site exceptions `[host: [permission: decision]]`, saved as `site_permissions.json` in the
/// profile folder. A store with no file (private sessions, tests) keeps decisions in memory only.
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
            sites = saved
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
        store.sites = sites
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

    private static func key(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        return host
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
        guard let url, url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return !(host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]"
                 || host.hasPrefix("127."))
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
