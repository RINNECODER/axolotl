import SwiftUI
import WebKit

/// Settings → Privacy & Data: the opt-in usage record and browsing data.
struct PersonalizationSettingsView: View {
    @AppStorage(PersonalizationPrefs.enabledKey) private var enabled = false
    @AppStorage(PersonalizationPrefs.retentionKey) private var retention = PersonalizationPrefs.defaultRetention
    @ObservedObject private var usage = UsageStore.forProfile(Usage.profileId())
    @State private var showData = false
    @State private var confirmDelete = false
    @State private var showClearHistory = false
    @State private var siteDataStatus: String?
    @State private var dataProfileId = ProfileManager.shared.lastActiveProfileId
    @ObservedObject private var profileManager = ProfileManager.shared

    var body: some View {
        Group {
            SettingsCard("Personalization", footer: "Off by default, and nothing is recorded while it's off. Agents change Axolotl only through its typed settings and tab tools — never code — and you approve each change.") {
                SettingsToggleRow("Keep a usage record",
                                  subtitle: "Counts the Axolotl features and shortcuts you use each day, on this Mac only. Your AI agent can read it, with your history, to set Axolotl up the way you use it.",
                                  isOn: $enabled)
                SettingsMenuRow("Keep data for", selection: $retention,
                                options: [.init(30, "30 days"), .init(90, "90 days"), .init(365, "1 year")])
                    .disabled(!enabled)
                SettingsRow("Recorded", subtitle: usage.isEmpty ? "Nothing yet" : "\(usage.days.count) \(usage.days.count == 1 ? "day" : "days")") {
                    Button("View Data…") { showData = true }
                    Button("Delete All…", role: .destructive) { confirmDelete = true }
                        .disabled(usage.isEmpty)
                }
            }

            SettingsCard("Privacy", footer: "Third-party cookies are always blocked: WebKit blocks cross-site tracking cookies by default.") {
                RegistryToggle("privacy.globalPrivacyControl")
                RegistryToggle("privacy.httpsFirst")
            }

            SettingsCard("Shields", footer: "Defaults for every site. Change one site from the Shields button next to the address bar; HTTPS upgrades follow the Privacy setting above.") {
                RegistryPicker("shields.level")
                RegistryToggle("shields.blockScripts")
            }

            SettingsCard("Browsing data") {
                if profileManager.profiles.count > 1 {
                    SettingsMenuRow("Profile", selection: $dataProfileId,
                                    options: profileManager.profiles.map { .init($0.id, $0.name) })
                }
                SettingsLinkRow("Clear browsing data", subtitle: "History, cookies and site data, cached files and downloads for a time range.",
                                icon: "clock.arrow.circlepath") {
                    showClearHistory = true
                }
                if let siteDataStatus { SettingsNoteRow(siteDataStatus) }
            }
        }
        .onChange(of: retention) { _, _ in usage.prune() }
        .sheet(isPresented: $showData) { UsageDataSheet(usage: usage) }
        .sheet(isPresented: $showClearHistory) {
            ClearBrowsingDataSheet(profileId: dataProfileId) { siteDataStatus = $0 }
        }
        .confirmationDialog("Delete the usage record?", isPresented: $confirmDelete) {
            Button("Delete All", role: .destructive) { usage.deleteAll() }
        } message: {
            Text("Removes every recorded count for this profile. Your browsing history is kept; clear it from History.")
        }
    }
}

/// "View Data": the record in plain words — features, shortcuts, active hours, top sites.
struct UsageDataSheet: View {
    @ObservedObject var usage: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var days = 30

    private var sites: [PersonalizationReport.Site] {
        PersonalizationReport.topSites(ProfileStoreRegistry.stores(for: Usage.profileId()).history.historyEvents, days: days, limit: 10)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Usage record").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                SettingsDropdown(title: "Period", selection: $days, options: [
                    .init(7, "7 days"), .init(30, "30 days"), .init(90, "90 days"), .init(365, "1 year"),
                ], minWidth: 110)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsCard("Features") {
                        let features = usage.featureTotals(days: days)
                        if features.isEmpty { SettingsNoteRow("None recorded") }
                        ForEach(features.prefix(12), id: \.feature) { item in
                            SettingsRow(item.feature.title) { Text("\(item.count)").monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                    let shortcuts = usage.shortcutTotals(days: days)
                    if !shortcuts.isEmpty {
                        SettingsCard("Keyboard shortcuts") {
                            ForEach(shortcuts.prefix(8), id: \.shortcut) { item in
                                SettingsRow(item.shortcut) { Text("\(item.count)").monospacedDigit().foregroundStyle(.secondary) }
                            }
                        }
                    }
                    SettingsCard("Active hours") {
                        SettingsContentRow {
                            HourBars(hours: usage.activeHours(days: days)).frame(height: 54)
                        }
                    }
                    SettingsCard("Top sites", footer: "From your browsing history; agents see domains, not full addresses.") {
                        if sites.isEmpty { SettingsNoteRow("No visits") }
                        ForEach(sites, id: \.domain) { site in
                            SettingsRow(site.domain) { Text("\(site.visits) visits").monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.settingsProminent)
            }
            .padding(12)
        }
        .frame(width: 460, height: 560)
        .background(SettingsStyle.page)
        .settingsControlStyles()
    }
}

private struct HourBars: View {
    let hours: [Int]

    var body: some View {
        let peak = max(1, hours.max() ?? 1)
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(hours.indices, id: \.self) { h in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(AxolotlSurface.accent.opacity(hours[h] == 0 ? 0.15 : 0.75))
                        .frame(height: max(2, 40 * CGFloat(hours[h]) / CGFloat(peak)))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 40, alignment: .bottom)
            HStack {
                Text("0:00"); Spacer(); Text("12:00"); Spacer(); Text("23:00")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("Activity by hour")
    }
}

/// Chrome-style "Clear browsing data": a time range and what to clear, from then to now, for one profile.
struct ClearBrowsingDataSheet: View {
    let profileId: UUID
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var range = TimeRange.hour
    @State private var history = true
    @State private var siteData = false
    @State private var cache = true
    @State private var downloads = false

    static let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                          WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]

    /// WebKit data types for the checked boxes; "cookies and site data" is everything but caches.
    static func websiteDataTypes(siteData: Bool, cache: Bool) -> Set<String> {
        let all = WKWebsiteDataStore.allWebsiteDataTypes()
        return (siteData ? all.subtracting(cacheTypes) : []).union(cache ? all.intersection(cacheTypes) : [])
    }

    enum TimeRange: String, CaseIterable, Identifiable {
        case hour, day, week, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hour: return "Last hour"
            case .day: return "Last 24 hours"
            case .week: return "Last 7 days"
            case .all: return "All time"
            }
        }
        var cutoff: Date {
            switch self {
            case .hour: return Date().addingTimeInterval(-3600)
            case .day: return Date().addingTimeInterval(-86_400)
            case .week: return Date().addingTimeInterval(-7 * 86_400)
            case .all: return .distantPast
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clear browsing data").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text("Removes what you choose from this time range in \(ProfileManager.shared.profile(for: profileId).name). Passwords and bookmarks are kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsCard {
                SettingsMenuRow("Time range", selection: $range, options: TimeRange.allCases.map { .init($0, $0.label) })
                SettingsToggleRow("Browsing history", isOn: $history)
                SettingsToggleRow("Cookies and site data", subtitle: "Signs you out of most websites.", isOn: $siteData)
                SettingsToggleRow("Cached images and files", isOn: $cache)
                SettingsToggleRow("Download list", subtitle: "Files you downloaded stay on disk.", isOn: $downloads)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clear data", role: .destructive, action: clear)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(history || siteData || cache || downloads))
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(SettingsStyle.page)
        .settingsControlStyles()
    }

    private func clear() {
        let cutoff = range.cutoff, done = "Browsing data cleared (\(range.label.lowercased()))."
        if history { ProfileStoreRegistry.stores(for: profileId).history.clearHistory(since: cutoff) }
        if downloads {
            DownloadManager.shared.clearInactive { $0.date >= cutoff && $0.belongs(profileId: profileId, isPrivate: false) }
        }
        let types = Self.websiteDataTypes(siteData: siteData, cache: cache)
        if types.isEmpty {
            onDone(done)
        } else {
            ProfileManager.shared.dataStore(for: profileId).removeData(ofTypes: types, modifiedSince: cutoff) { onDone(done) }
        }
        dismiss()
    }
}
