import SwiftUI

/// The Personalize preview: each proposed change as "Name  old → new" with a checkbox,
/// then Apply / Cancel. After applying it offers Undo. Same look as the other panel cards.
struct CustomizationCardView: View {
    enum Action {
        case toggle(String)
        case apply
        case cancel
        case undo
        case openSettings
    }

    let card: CustomizationCard
    let fontSize: CGFloat
    let onAction: (Action) -> Void

    private var isPending: Bool { card.status == .ready && !card.items.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            if card.status == .thinking {
                secondary(card.usedUsage ? "Reading your usage and Axolotl's settings…" : "Reading Axolotl's settings…")
            }
            if !card.note.isEmpty, card.status != .thinking {
                secondary(card.note)
            }
            if !card.items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(card.items) { item in
                        row(item)
                        if item.id != card.items.last?.id {
                            Divider().overlay(Color.white.opacity(0.06))
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.22)))
            }
            if !card.rejected.isEmpty {
                Text("Skipped: " + card.rejected.joined(separator: "; "))
                    .font(.system(size: 10.5))
                    .foregroundColor(ChatTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = card.message {
                secondary(message)
            }
            if !card.usedUsage, card.status != .thinking {
                HStack(spacing: 4) {
                    Text("Usage record is off.")
                    Button("Turn on in Settings…") { onAction(.openSettings) }
                        .buttonStyle(.link)
                }
                .font(.system(size: 10.5))
                .foregroundColor(ChatTokens.textTertiary)
            }
            footer
        }
        .chatCard(tint: isPending ? ChatTokens.accent : nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Personalize proposal")
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            ChatStatusIcon(state: statusIcon)
            Text(title)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(ChatTokens.textPrimary)
            Spacer(minLength: 0)
            if !card.source.isEmpty {
                Text(card.source)
                    .font(.system(size: 10.5))
                    .foregroundColor(ChatTokens.textTertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch card.status {
        case .thinking: return "Personalizing…"
        case .ready: return card.items.isEmpty ? "Nothing to change" : "Suggested changes"
        case .applied: return "Applied"
        case .undone: return "Undone"
        case .cancelled: return "Not applied"
        case .failed: return "No proposal"
        }
    }

    private var statusIcon: ChatStatusIcon.State {
        switch card.status {
        case .thinking: return .running
        case .ready: return card.items.isEmpty ? .done : .pending
        case .applied: return .done
        case .undone, .cancelled: return .stopped
        case .failed: return .warning
        }
    }

    private func row(_ item: CustomizationCard.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isPending {
                Toggle(isOn: Binding(get: { item.include }, set: { _ in onAction(.toggle(item.id)) })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Include \(item.line.title)")
            }
            Text(item.line.title)
                .font(.system(size: fontSize - 1, weight: .medium))
                .foregroundColor(item.include ? ChatTokens.textPrimary : ChatTokens.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if let from = item.line.from {
                    Text(from).foregroundColor(ChatTokens.textTertiary)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                        .foregroundColor(ChatTokens.textTertiary)
                }
                Text(item.line.to).foregroundColor(item.include ? ChatTokens.textSecondary : ChatTokens.textTertiary)
            }
            .font(.system(size: fontSize - 1.5))
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        switch card.status {
        case .ready where !card.items.isEmpty:
            HStack(spacing: 6) {
                Button("Apply") { onAction(.apply) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!card.items.contains(where: \.include))
                Button("Cancel") { onAction(.cancel) }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        case .applied:
            HStack(spacing: 6) {
                Button("Undo") { onAction(.undo) }
                Spacer(minLength: 0)
                Text("Also in Settings → Personalization")
                    .font(.system(size: 10.5))
                    .foregroundColor(ChatTokens.textTertiary)
            }
            .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.system(size: fontSize - 1))
            .foregroundColor(ChatTokens.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
