import SwiftUI

/// Settings → Personalization: the opt-in usage record, and the AI changes made with it.
struct PersonalizationSettingsView: View {
    @AppStorage(PersonalizationPrefs.enabledKey) private var enabled = false
    @AppStorage(PersonalizationPrefs.retentionKey) private var retention = PersonalizationPrefs.defaultRetention
    @ObservedObject private var usage = UsageStore.forProfile(Usage.profileId())
    @ObservedObject private var log = AIChangeLog.shared
    @State private var showData = false
    @State private var confirmDelete = false
    @State private var undoError: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Text("Keep a usage record")
                    Text("Counts the Luna features and shortcuts you use each day, on this Mac only. Your AI agent can read it, with your history, to set Luna up the way you use it.")
                }
                LunaPicker("Keep data for", selection: $retention,
                           options: [.init(30, "30 days"), .init(90, "90 days"), .init(365, "1 year")])
                .disabled(!enabled)
                LabeledContent("Recorded") {
                    HStack(spacing: 8) {
                        Text(usage.isEmpty ? "Nothing yet" : "\(usage.days.count) \(usage.days.count == 1 ? "day" : "days")")
                            .foregroundStyle(.secondary)
                        Button("View Data…") { showData = true }
                        Button("Delete All…", role: .destructive) { confirmDelete = true }
                            .disabled(usage.isEmpty)
                    }
                }
            } footer: {
                Text("Off by default, and nothing is recorded while it's off. Agents change Luna only through its typed settings and tab tools — never code — and you approve each change.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if log.entries.isEmpty {
                    Text("Changes your AI agent makes appear here, with Undo.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(log.entries) { entry in
                        ChangeRow(entry: entry) {
                            do { _ = try Customizer.shared.undo(entry.id) } catch { undoError = error.localizedDescription }
                        }
                    }
                }
            } header: {
                Text("Recent AI changes")
            }
        }
        .formStyle(.grouped)
        .onChange(of: retention) { _, _ in usage.prune() }
        .sheet(isPresented: $showData) { UsageDataSheet(usage: usage) }
        .confirmationDialog("Delete the usage record?", isPresented: $confirmDelete) {
            Button("Delete All", role: .destructive) { usage.deleteAll() }
        } message: {
            Text("Removes every recorded count for this profile. Your browsing history is kept; clear it from History.")
        }
        .alert("Couldn't undo", isPresented: Binding(get: { undoError != nil }, set: { if !$0 { undoError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(undoError ?? "")
        }
    }
}

private struct ChangeRow: View {
    let entry: AIChange
    let onUndo: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entry.lines.prefix(2), id: \.self) { line in
                    Text(line.text).strikethrough(entry.undone).lineLimit(1)
                }
                if entry.lines.count > 2 {
                    Text("and \(entry.lines.count - 2) more").foregroundStyle(.secondary)
                }
                Text("\(entry.source) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if entry.undone {
                Text("Undone").foregroundStyle(.secondary)
            } else {
                Button("Undo", action: onUndo)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "View Data": the record in plain words — features, shortcuts, active hours, top sites.
private struct UsageDataSheet: View {
    @ObservedObject var usage: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var days = 30

    private var sites: [PersonalizationReport.Site] {
        PersonalizationReport.topSites(ProfileStoreRegistry.stores(for: Usage.profileId()).history.historyEvents, days: days, limit: 10)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Usage record").font(.headline)
                Spacer()
                LunaPicker("Period", selection: $days, options: [
                    .init(7, "7 days"), .init(30, "30 days"), .init(90, "90 days"), .init(365, "1 year"),
                ])
                .labelsHidden()
                .fixedSize()
            }
            .padding(16)
            Divider()
            Form {
                Section("Features") {
                    let features = usage.featureTotals(days: days)
                    if features.isEmpty { Text("None recorded").foregroundStyle(.secondary) }
                    ForEach(features.prefix(12), id: \.feature) { item in
                        LabeledContent(item.feature.title) { Text("\(item.count)").monospacedDigit() }
                    }
                }
                let shortcuts = usage.shortcutTotals(days: days)
                if !shortcuts.isEmpty {
                    Section("Keyboard shortcuts") {
                        ForEach(shortcuts.prefix(8), id: \.shortcut) { item in
                            LabeledContent(item.shortcut) { Text("\(item.count)").monospacedDigit() }
                        }
                    }
                }
                Section("Active hours") {
                    HourBars(hours: usage.activeHours(days: days))
                        .frame(height: 54)
                        .padding(.vertical, 4)
                }
                Section {
                    if sites.isEmpty { Text("No visits").foregroundStyle(.secondary) }
                    ForEach(sites, id: \.domain) { site in
                        LabeledContent(site.domain) { Text("\(site.visits) visits").monospacedDigit() }
                    }
                } header: {
                    Text("Top sites")
                } footer: {
                    Text("From your browsing history; agents see domains, not full addresses.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 560)
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
                        .fill(Color.accentColor.opacity(hours[h] == 0 ? 0.15 : 0.75))
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
