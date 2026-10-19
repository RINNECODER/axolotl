import SwiftUI
import WebKit

/// Settings → Privacy & Data: the opt-in usage record and browsing data.
struct PersonalizationSettingsView: View {
    @AppStorage(PersonalizationPrefs.enabledKey) private var enabled = false
    @AppStorage(PersonalizationPrefs.retentionKey) private var retention = PersonalizationPrefs.defaultRetention
    @ObservedObject private var usage = UsageStore.forProfile(Usage.profileId())
    @State private var showData = false
    @State private var confirmDelete = false
    @State private var confirmClearSiteData = false
    @State private var showClearHistory = false
    @State private var siteDataStatus: String?
    @State private var dataProfileId = ProfileManager.shared.lastActiveProfileId
    @ObservedObject private var profileManager = ProfileManager.shared

    var body: some View {
        Group {
            SettingsCard("Personalization", footer: "Off by default, and nothing is recorded while it's off. Agents change Luna only through its typed settings and tab tools — never code — and you approve each change.") {
                SettingsToggleRow("Keep a usage record",
                                  subtitle: "Counts the Luna features and shortcuts you use each day, on this Mac only. Your AI agent can read it, with your history, to set Luna up the way you use it.",
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

            SettingsCard("Browsing data") {
                if profileManager.profiles.count > 1 {
                    SettingsMenuRow("Profile", selection: $dataProfileId,
                                    options: profileManager.profiles.map { .init($0.id, $0.name) })
                }
                SettingsRow("Cookies and site data", subtitle: "Signs you out of websites in this profile.", icon: "externaldrive") {
                    Button("Clear…", role: .destructive) { confirmClearSiteData = true }
                }
                SettingsLinkRow("Clear browsing data", subtitle: "Clear history for a time range.", icon: "clock.arrow.circlepath") {
                    showClearHistory = true
                }
                if let siteDataStatus { SettingsNoteRow(siteDataStatus) }
            }
        }
        .onChange(of: retention) { _, _ in usage.prune() }
        .sheet(isPresented: $showData) { UsageDataSheet(usage: usage) }
        .sheet(isPresented: $showClearHistory) {
            ClearHistorySheet(history: ProfileStoreRegistry.stores(for: dataProfileId).history) { siteDataStatus = $0 }
        }
        .confirmationDialog("Clear cookies and site data for \(profileManager.profile(for: dataProfileId).name)?",
                            isPresented: $confirmClearSiteData) {
            Button("Clear", role: .destructive, action: clearSiteData)
        } message: {
            Text("Signs you out of websites in this profile. Saved passwords and history are kept.")
        }
        .confirmationDialog("Delete the usage record?", isPresented: $confirmDelete) {
            Button("Delete All", role: .destructive) { usage.deleteAll() }
        } message: {
            Text("Removes every recorded count for this profile. Your browsing history is kept; clear it from History.")
        }
    }

    private func clearSiteData() {
        let store = ProfileManager.shared.dataStore(for: dataProfileId)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            siteDataStatus = "Cookies and site data cleared."
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
                        .fill(LunaSurface.accent.opacity(hours[h] == 0 ? 0.15 : 0.75))
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

/// Chrome-style "Clear browsing data": pick a time range, confirm, clear history from then to now.
struct ClearHistorySheet: View {
    let history: HistoryManager
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var range = TimeRange.hour

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
            Text("Clear browsing history").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text("Removes the pages you visited in this time range from History on this Mac. Cookies, passwords and bookmarks are kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsCard {
                SettingsMenuRow("Time range", selection: $range, options: TimeRange.allCases.map { .init($0, $0.label) })
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clear history", role: .destructive) {
                    history.clearHistory(since: range.cutoff)
                    onDone("History cleared (\(range.label.lowercased())).")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(SettingsStyle.page)
        .settingsControlStyles()
    }
}
