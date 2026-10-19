import Foundation
import WebKit

/// Settings → Privacy & Data: Global Privacy Control and HTTPS-first. Both default on (Brave).
/// Third-party cookies: WebKit has no per-store third-party policy API (only allow/disallow all),
/// and WKWebView already blocks third-party cookies by default (ITP), so Axolotl has no toggle for it.
enum PrivacyPrefs {
    static let globalPrivacyControl = "axolotl_privacy_gpc"
    static let httpsFirst = "axolotl_privacy_https_first"

    static func isOn(_ key: String, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    /// GPC: WKWebView can't add a header to every request (subresources, redirects and page-started
    /// loads go out untouched), so `Sec-GPC: 1` rides only on main-frame loads Axolotl starts, and
    /// `navigator.globalPrivacyControl` (what most sites check) is set in every frame at document start.
    static let gpcScriptSource = """
    (() => { try { Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', \
    { get: () => true, configurable: true, enumerable: true }); } catch (e) {} })();
    """

    static func gpcScript() -> WKUserScript {
        WKUserScript(source: gpcScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}

/// HTTPS-first: typed and clicked http:// pages try https:// first; when that fails, the error
/// page offers "Continue to http".
enum HTTPSUpgrade {
    /// The https URL to try for `url`, or nil to load it as is (not http, a local or bare host,
    /// an explicit non-80 port, or a host the user chose to continue to over http).
    static func upgrade(_ url: URL, exempt: Set<String> = []) -> URL? {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased(), !host.isEmpty,
              url.port == nil || url.port == 80, !exempt.contains(host), !isLocal(host),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        parts.port = nil
        return parts.url
    }

    /// Hosts with no public certificate: localhost, *.local, single-label names and IP literals.
    static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".")
            || host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    }
}
