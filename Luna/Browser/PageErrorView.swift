// Luna — Chrome-style native error page for a tab whose load failed or whose web process crashed.
import SwiftUI
import WebKit

/// Why a tab shows an error page instead of its web content.
struct PageError: Equatable {
    enum Kind: Equatable {
        case noInternet, dnsFailed, connectionRefused, timedOut, secureConnectionFailed, cantReach
        /// The web content process died ("Aw, Snap!").
        case crashed
    }

    var kind: Kind
    /// The page that failed (nil when unknown); Reload loads it again.
    var url: URL?
    var code: Int?
    /// HTTPS-first: the http page the failed https try stood in for ("Continue to http").
    var httpFallback: URL? = nil

    var host: String { url?.host ?? url?.absoluteString ?? "" }

    var title: String {
        switch kind {
        case .noInternet: return "No internet"
        case .dnsFailed, .connectionRefused, .timedOut, .cantReach: return "This site can't be reached"
        case .secureConnectionFailed: return "This site can't provide a secure connection"
        case .crashed: return "Aw, Snap!"
        }
    }

    var message: String {
        let site = host.isEmpty ? "The site" : host
        switch kind {
        case .noInternet: return "Check your network cables, modem and router, or reconnect to Wi-Fi."
        case .dnsFailed: return "\(site)'s server IP address could not be found."
        case .connectionRefused: return "\(site) refused to connect."
        case .timedOut: return "\(site) took too long to respond."
        case .secureConnectionFailed: return "\(site) sent an invalid response or its certificate isn't trusted."
        case .cantReach: return "\(site) can't be reached right now."
        case .crashed: return "Something went wrong while displaying this webpage."
        }
    }

    var symbol: String {
        switch kind {
        case .noInternet: return "wifi.slash"
        case .secureConnectionFailed: return "lock.slash"
        case .crashed: return "exclamationmark.triangle"
        default: return "globe"
        }
    }

    /// Maps a failed provisional load to an error page, or nil when nothing
    /// should be shown (the user stopped it, a new load replaced it, or the
    /// response became a download / was handled elsewhere).
    static func classify(_ error: Error, url fallback: URL?) -> PageError? {
        let ns = error as NSError
        let url = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? fallback
        if ns.domain == NSURLErrorDomain {
            let kind: Kind
            switch ns.code {
            case NSURLErrorCancelled:
                return nil
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
                 NSURLErrorInternationalRoamingOff:
                kind = .noInternet
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                kind = .dnsFailed
            case NSURLErrorCannotConnectToHost:
                kind = .connectionRefused
            case NSURLErrorTimedOut:
                kind = .timedOut
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                kind = .secureConnectionFailed
            default:
                kind = .cantReach
            }
            return PageError(kind: kind, url: url, code: ns.code)
        }
        // WebKit's own errors: 101 = can't show URL, 103 = blocked port (e.g. :1, Chrome's
        // ERR_UNSAFE_PORT) never reach the network, so show the page. 102 = frame load
        // interrupted by policy change (downloads, handled navigations) and WKError.* (JS/content
        // errors) show nothing.
        if ns.domain == "WebKitErrorDomain", ns.code == 101 || ns.code == 103 {
            return PageError(kind: .cantReach, url: url, code: ns.code)
        }
        if ns.domain == "WebKitErrorDomain" || ns.domain == WKError.errorDomain { return nil }
        return PageError(kind: .cantReach, url: url, code: ns.code)
    }
}

/// The error page itself, drawn over the tab's web view.
struct PageErrorView: View {
    let error: PageError
    let onReload: () -> Void
    var onContinueHTTP: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: error.symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text(error.title)
                    .font(.system(size: 22, weight: .semibold))
                Text(error.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let code = error.code, error.kind != .crashed {
                    Text(verbatim: "Error code: \(code)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if error.httpFallback != nil {
                    Text("Luna tried a secure (https) connection first. The http page isn't encrypted.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button("Reload", action: onReload)
                    if error.httpFallback != nil, let onContinueHTTP {
                        Button("Continue to http", action: onContinueHTTP)
                    }
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
