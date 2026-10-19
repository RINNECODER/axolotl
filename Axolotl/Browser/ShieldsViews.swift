import SwiftUI

/// Toolbar Shields button (Brave): the active site's Shields state and blocked count; opens the panel.
struct ShieldsButton: View {
    let web: WebViewWrapper
    @ObservedObject var extensions: ExtensionHost
    @ObservedObject private var shields: ShieldsStore
    let tabId: UUID?
    let url: URL?
    @State private var isPresented = false

    init(web: WebViewWrapper, extensions: ExtensionHost, tabId: UUID?, url: URL?) {
        self.web = web
        self.extensions = extensions
        _shields = ObservedObject(wrappedValue: web.shields)
        self.tabId = tabId
        self.url = url
    }

    var body: some View {
        if let tabId, let host = ShieldsStore.host(of: url) {
            let _ = extensions.actionRevision
            let blocked = extensions.blockedCount(for: tabId)
            let up = shields.policy(host: host).up
            Button { isPresented.toggle() } label: {
                Image(systemName: up ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(up ? Color.orange : Color.secondary)
                    .frame(width: ChromeMetrics.toolbarButton, height: ChromeMetrics.toolbarButton)
                    .overlay(alignment: .topTrailing) {
                        if up && blocked > 0 { ShieldsBadge(count: blocked) }
                    }
                    .chromeButtonHover(isOpen: isPresented)
            }
            .buttonStyle(.plain)
            .help("Shields")
            .accessibilityLabel("Shields")
            .accessibilityValue(up ? "Up, \(blocked) blocked" : "Down")
            .axolotlPopover(isPresented: $isPresented, arrowEdge: .bottom) {
                ShieldsPanel(host: host, blocked: blocked, store: shields, hasAdBlocker: extensions.hasAdBlocker) {
                    // Reload once uBOL has the new mode, so the page loads under it.
                    Task {
                        await extensions.applyShields(host: host)
                        web.reload(in: tabId)
                    }
                }
            }
        }
    }
}

private struct ShieldsBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 8, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .frame(minWidth: 12, minHeight: 12)
            .background(Capsule().fill(Color.gray))
            .offset(x: 3, y: -1)
            .accessibilityHidden(true)
    }
}

/// The Shields panel: one site's Shields toggle, blocked count and options. Every change reloads the page.
struct ShieldsPanel: View {
    let host: String
    let blocked: Int
    @ObservedObject var store: ShieldsStore
    var hasAdBlocker = true
    let onChange: () -> Void

    var body: some View {
        let policy = store.policy(host: host)
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                Text(host)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shields are \(policy.up ? "UP" : "DOWN")")
                            .font(.system(size: 15, weight: .bold))
                        Text("for this site")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Shields for \(host)", isOn: binding(\.up))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.large)
                        .tint(.orange)
                }
                if policy.up {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(blocked)").font(.system(size: 26, weight: .bold).monospacedDigit())
                        Text("trackers & ads blocked on this page").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("You've turned Shields off for this site. Ads, trackers and scripts aren't blocked.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Trackers & ads blocking")
                    Spacer()
                    Picker("Trackers & ads blocking", selection: binding(\.level)) {
                        ForEach(ShieldsLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!hasAdBlocker)
                }
                switchRow("Upgrade connections to HTTPS", binding(\.httpsUpgrade))
                switchRow("Block scripts", binding(\.blockScripts))
                if !hasAdBlocker {
                    Text("Turn on uBlock Origin Lite in Extensions to block ads and trackers.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            .disabled(!policy.up)
            .padding(14)
        }
        .frame(width: 300)
    }

    private func switchRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden()
        }
    }

    private func binding<T>(_ key: WritableKeyPath<ShieldsPolicy, T>) -> Binding<T> {
        Binding(get: { store.policy(host: host)[keyPath: key] },
                set: { value in
                    store.update(host: host) { $0[keyPath: key] = value }
                    onChange()
                })
    }
}

/// Start page line (Brave): trackers and ads blocked in this profile since install.
struct ShieldsStatLine: View {
    @ObservedObject var counter: ShieldsCounter

    var body: some View {
        if counter.total > 0 {
            Label("\(counter.total.formatted()) trackers & ads blocked", systemImage: "shield.lefthalf.filled")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
