import SwiftUI

/// Settings → Site Settings (Chrome: Privacy and security → Site settings): what sites may use by
/// default, and the sites with their own settings, per profile.
struct SiteSettingsView: View {
    @State private var profileId = ProfileManager.shared.lastActiveProfileId
    @ObservedObject private var profileManager = ProfileManager.shared

    var body: some View {
        Group {
            SettingsCard("Permissions", footer: "Sites ask before using your camera, microphone or location unless you block them here. Blocked pop-ups still open from a click. Notifications aren't supported by WebKit yet.") {
                ForEach(SitePermission.allCases) { RegistryPicker($0.registryKey) }
            }
            SettingsCard("Sites with their own settings") {
                if profileManager.profiles.count > 1 {
                    SettingsMenuRow("Profile", selection: $profileId,
                                    options: profileManager.profiles.map { .init($0.id, $0.name) })
                }
                SiteExceptionsList(store: .forProfile(profileId))
            }
            SettingsCard("Shields exceptions") {
                ShieldsExceptionsList(store: .forProfile(profileId))
            }
        }
    }
}

private struct SiteExceptionsList: View {
    @ObservedObject var store: SitePermissionStore

    var body: some View {
        let hosts = store.sites.keys.sorted()
        if hosts.isEmpty {
            SettingsNoteRow("No sites yet. Choices you make with Remember on show up here.")
        }
        ForEach(hosts, id: \.self) { host in
            SettingsRow(host, icon: "globe") {
                Button("Remove", role: .destructive) { store.removeAll(host: host) }
                    .accessibilityLabel("Remove \(host)")
            }
            ForEach(SitePermission.allCases.filter { store.sites[host]?[$0] != nil }) { p in
                SettingsMenuRow("    \(p.title)",
                                selection: Binding(get: { store.decision(p, host: host) }, set: { store.set($0, p, host: host) }),
                                options: p.choices.map { .init($0, $0.title(for: p)) })
            }
        }
    }
}

private struct ShieldsExceptionsList: View {
    @ObservedObject var store: ShieldsStore

    var body: some View {
        let hosts = store.sites.keys.sorted()
        if hosts.isEmpty {
            SettingsNoteRow("No sites yet. Sites you change with the Shields button show up here.")
        }
        ForEach(hosts, id: \.self) { host in
            SettingsRow(host, subtitle: Self.summary(store.policy(host: host)), icon: "shield.lefthalf.filled") {
                Button("Remove", role: .destructive) { store.remove(host: host) }
                    .accessibilityLabel("Remove Shields settings for \(host)")
            }
        }
    }

    static func summary(_ p: ShieldsPolicy) -> String {
        guard p.up else { return "Shields down" }
        return ["Trackers & ads: \(p.level.title)", p.httpsUpgrade ? nil : "No HTTPS upgrade",
                p.blockScripts ? "Scripts blocked" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}
