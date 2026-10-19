import SwiftUI
import WebKit

/// Chrome's permission prompt: "<host> wants to" + what, Allow / Block, and Remember (on by default).
struct SitePermissionBubble: View {
    let request: SitePermissionRequest
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(request.host) wants to")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button { request.respond(allow: false, remember: false) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            ForEach(request.permissions) { p in
                Label(p.request, systemImage: p.icon).font(.system(size: 13))
            }
            Toggle("Remember this decision", isOn: $remember)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            HStack(spacing: 8) {
                Spacer()
                Button("Block") { request.respond(allow: false, remember: remember) }.buttonStyle(.settings)
                Button("Allow") { request.respond(allow: true, remember: remember) }.buttonStyle(.settingsProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AxolotlSurface.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AxolotlSurface.stroke))
        .compositingGroup()
        .shadow(color: AxolotlSurface.shadow, radius: 12, y: 5)
    }
}

/// The site-info popover from the address field's lock/globe: connection, this site's permissions,
/// cookies and site data, and a link to Site settings.
struct SiteInfoPopover: View {
    let url: URL
    @ObservedObject var store: SitePermissionStore
    /// The page's web view (certificate, data store); nil when unloaded.
    let webView: WKWebView?
    /// The tab is showing a load error (e.g. a certificate failure), so nothing on screen is the secure page.
    var hasPageError = false
    /// The profile for "Forget me when I close this site"; nil hides it (private windows).
    var forgetProfileId: UUID? = nil
    var onClose: () -> Void = {}
    @State private var records: [WKWebsiteDataRecord]?
    @State private var forget = false

    private var host: String { url.host ?? "" }
    private var origin: String { SitePermissionStore.origin(url) ?? host }
    private var secure: Bool { SiteSecurity.isSecure(url, webView: webView, hasPageError: hasPageError) }
    private var notSecure: Bool { !secure && (url.scheme == "https" || hasPageError || SiteSecurity.showsNotSecure(url)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(host).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .padding(.bottom, 12)
            row(secure ? "lock.fill" : (notSecure ? "exclamationmark.triangle" : "info.circle")) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(secure ? "Connection is secure" : (notSecure ? "Connection is not secure" : "This page is on your Mac"))
                        .font(.system(size: 13))
                    if secure, let issuer = SiteSecurity.certificateIssuer(webView) {
                        Text("Certificate issued by \(issuer)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else if notSecure {
                        Text("Don't enter passwords or payment details on this site.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
            Divider().padding(.vertical, 10)
            Text("Permissions").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(SitePermission.allCases) { p in
                row(p.icon) {
                    Text(p.title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 8)
                    SettingsDropdown(title: p.title,
                                     selection: Binding(get: { store.decision(p, host: origin) },
                                                        set: { store.set($0, p, host: origin) }),
                                     options: p.choices.map { .init($0, $0.title(for: p)) }, minWidth: 96)
                }
            }
            Divider().padding(.vertical, 10)
            row("externaldrive") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cookies and site data").font(.system(size: 13))
                    Text(records.map { $0.isEmpty ? "None stored" : "\($0.count) \($0.count == 1 ? "site" : "sites") in use" } ?? "…")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Clear site data", role: .destructive, action: clear)
                    .buttonStyle(.settings)
                    .disabled(records?.isEmpty ?? true)
            }
            if let profileId = forgetProfileId, ForgetSites.site(url.host) != nil {
                row("eye.slash") {
                    Toggle("Forget me when I close this site", isOn: Binding(get: { forget }, set: {
                        forget = $0
                        ForgetSites.set($0, host: url.host, profileId: profileId)
                    }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .help("Clears this site's cookies and data when you close its last tab.")
                }
                .onAppear { forget = ForgetSites.isOn(host: url.host, profileId: profileId) }
            }
            Divider().padding(.vertical, 10)
            Button {
                onClose()
                SettingsOpener.open(.siteSettings)
            } label: {
                row("gearshape") {
                    Text("Site settings").font(.system(size: 13))
                    Spacer()
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 340)
        .task { await load() }
    }

    private func row<C: View>(_ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
            content()
        }
        .frame(minHeight: 30)
    }

    private func load() async {
        guard let dataStore = webView?.configuration.websiteDataStore else { return records = [] }
        let all = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        records = SiteSecurity.records(all, for: host)
    }

    private func clear() {
        guard let dataStore = webView?.configuration.websiteDataStore, let records, !records.isEmpty else { return }
        Task {
            await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
            await load()
        }
    }
}
