import AppKit
import SwiftUI

// Cards in the AI panel conversation: agent runs, key grabs and approvals.
// Same look as the chat around them (ChatStyle.swift): soft rounded blocks, small type,
// system buttons.

// MARK: - Message row

/// A chat message: the regular bubble, or the run / grab card it carries.
struct PanelMessageRow: View {
    let message: ChatMessage
    let fontSize: CGFloat
    var onLinkTapped: ((URL) -> Void)?
    var onStopRun: (() -> Void)?
    var onResumeGrab: ((GrabCard) -> Void)?
    var onDismissGrab: (() -> Void)?
    var onPersonalize: ((CustomizationCardView.Action) -> Void)?
    var isLastMessage = false

    var body: some View {
        if let card = message.card {
            switch card {
            case .agentRun(let run):
                AgentRunView(run: run, fontSize: fontSize, onStop: isLastMessage ? onStopRun : nil)
            case .grab(let grab):
                GrabCardView(card: grab, fontSize: fontSize, isCurrent: isLastMessage, onStop: onStopRun,
                             onResume: { onResumeGrab?(grab) }, onDismiss: onDismissGrab)
            case .personalize(let card):
                CustomizationCardView(card: card, fontSize: fontSize) { onPersonalize?($0) }
            }
        } else {
            AxolotlChatBubble(message: message, isUser: message.role == .user, fontSize: fontSize,
                           onLinkTapped: onLinkTapped)
        }
    }
}

// MARK: - Agent run

/// A compact live list of agent steps (operation, target, confidence), collapsible, with Stop.
struct AgentRunView: View {
    let run: AgentRunCard
    let fontSize: CGFloat
    var title = "Agent"
    var onStop: (() -> Void)?
    /// nil follows the run: open while running or short, closed once a long run ends.
    @State private var expandedOverride: Bool?

    private var expanded: Bool { expandedOverride ?? (run.isRunning || run.steps.count <= 4) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded, !run.steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(run.steps) { step in
                        AgentStepRow(step: step, fontSize: fontSize,
                                     isLatest: run.isRunning && step.id == run.steps.last?.id)
                    }
                }
            }
            if let note = run.note, run.isRunning {
                Text(note)
                    .font(.system(size: fontSize - 2))
                    .foregroundColor(ChatTokens.textTertiary)
            }
            if run.isRunning {
                if run.steps.isEmpty { AxolotlSayingRow(fontSize: fontSize) }
            } else {
                outcome
            }
        }
        .chatCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(run.goal)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 12))
                .foregroundColor(ChatTokens.accent)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.goal)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(ChatTokens.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(title) · \(run.model)")
                    .font(.system(size: 10.5))
                    .foregroundColor(ChatTokens.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if run.isRunning, let onStop {
                Button("Stop", action: onStop)
                    .controlSize(.small)
                    .help("Stop the agent (Esc)")
            }
            if !run.steps.isEmpty {
                PanelIconButton(systemName: expanded ? "chevron.up" : "chevron.down",
                                help: expanded ? "Hide steps" : "Show steps") {
                    expandedOverride = !expanded
                }
                .frame(width: 22, height: 22)
            }
        }
    }

    private var outcome: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ChatStatusIcon(state: statusIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.outcomeLine)
                    .font(.system(size: fontSize - 1, weight: .medium))
                    .foregroundColor(ChatTokens.textSecondary)
                if let reason = run.reason {
                    Text(reason)
                        .font(.system(size: fontSize - 1))
                        .foregroundColor(ChatTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusIcon: ChatStatusIcon.State {
        switch run.status {
        case .running: return .running
        case .done: return .done
        case .blocked: return .warning
        case .stopped: return .stopped
        case .failed: return .failed
        }
    }
}

private struct AgentStepRow: View {
    let step: AgentRunCard.Step
    let fontSize: CGFloat
    let isLatest: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(step.id)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(ChatTokens.textTertiary)
                .frame(width: 16, alignment: .trailing)
            Text(step.operation)
                .font(.system(size: fontSize - 1, weight: .semibold))
                .foregroundColor(ChatTokens.textPrimary)
            Text(targetText)
                .font(.system(size: fontSize - 1))
                .foregroundColor(ChatTokens.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if isLatest && !step.executed {
                ChatStatusIcon(state: .running)
            } else if step.noChange {
                Text("no change")
                    .font(.system(size: 10.5))
                    .foregroundColor(.orange)
            }
            if let c = step.confidence {
                Text(String(format: "%.0f%%", c * 100))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(ChatTokens.textTertiary)
                    .help("Model confidence in this action")
            }
        }
        .help("\(step.latencyMs) ms")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private var targetText: String {
        [step.target, step.result ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var accessibility: String {
        var s = "Step \(step.id): \(step.operation) \(targetText)"
        if let c = step.confidence { s += String(format: ", %.0f percent confidence", c * 100) }
        if step.noChange { s += ", no change" }
        return s
    }
}

// MARK: - Key grab

struct GrabCardView: View {
    let card: GrabCard
    let fontSize: CGFloat
    let isCurrent: Bool
    var onStop: (() -> Void)?
    var onResume: () -> Void
    var onDismiss: (() -> Void)?
    @State private var copied = false

    var body: some View {
        switch card.status {
        case .running:
            AgentRunView(run: card.run, fontSize: fontSize, title: "Key grab", onStop: isCurrent ? onStop : nil)
        case .waitingForSignIn:
            VStack(alignment: .leading, spacing: 8) {
                titleRow(icon: .pending, title: "Sign in to \(card.serviceName)")
                bodyText("Sign in to \(card.serviceName) in this tab, then resume. Axolotl never types passwords.")
                if isCurrent {
                    HStack(spacing: 8) {
                        Button("Resume", action: onResume)
                            .buttonStyle(.borderedProminent)
                        Button("Cancel") { onDismiss?() }
                    }
                    .controlSize(.small)
                }
            }
            .chatCard()
        case .saved:
            VStack(alignment: .leading, spacing: 8) {
                titleRow(icon: .done, title: "\(card.serviceName) key saved")
                bodyText("Saved to Keychain + clipboard, not shared with the agent.")
                if let item = card.keychainItem {
                    Text(item)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(ChatTokens.textTertiary)
                        .textSelection(.enabled)
                        .accessibilityLabel("Keychain item \(item)")
                }
                Button(copied ? "Copied" : "Copy Key Again") {
                    copied = SecretVault.shared.copy(account: "\(card.serviceID)/\(card.keyName)")
                }
                .controlSize(.small)
            }
            .chatCard(tint: ChatTokens.accent)
        case .notFound, .failed, .stopped:
            VStack(alignment: .leading, spacing: 8) {
                titleRow(icon: card.status == .stopped ? .stopped : .warning,
                         title: card.status == .stopped ? "Key grab stopped" : "No key saved")
                if !card.message.isEmpty, card.status != .stopped {
                    bodyText(card.message)
                }
                if !card.run.steps.isEmpty {
                    AgentRunView(run: card.run, fontSize: fontSize, title: "Key grab")
                }
            }
            .chatCard()
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: fontSize - 0.5))
            .foregroundColor(ChatTokens.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func titleRow(icon: ChatStatusIcon.State, title: String) -> some View {
        HStack(spacing: 6) {
            ChatStatusIcon(state: icon)
            Text(title).font(.system(size: fontSize, weight: .semibold)).foregroundColor(ChatTokens.textPrimary)
            Spacer(minLength: 0)
            Text(card.keyName)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(ChatTokens.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty state

/// The panel's empty state: the ASCII axolotl, a serif title, capsule suggestions.
struct ChatEmptyState: View {
    struct Suggestion: Identifiable {
        var id: String { title }
        let title: String
        let action: () -> Void
    }

    let title: String
    let subtitle: String
    let suggestions: [Suggestion]
    var isBusy = false

    var body: some View {
        VStack(spacing: 0) {
            AsciiAxolotl(diameter: 92, isBusy: isBusy)
                .padding(.bottom, 2)
            Text(title)
                .font(AxolotlType.brand(size: 22))
                .foregroundStyle(Color.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(ChatTokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
            VStack(spacing: 6) {
                ForEach(suggestions) { suggestion in
                    Button(action: suggestion.action) {
                        Text(suggestion.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(ChatTokens.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Approvals

/// "May the agent do this?" with Allow / Allow for Session / Deny, details on demand.
/// Used for Dev mode CLI approvals and for outside agents (MCP).
struct PanelApprovalCard: View {
    enum Decision { case allow, allowForSession, deny }
    enum State: Equatable { case pending, decided(String), expired }

    let systemImage: String
    let title: String
    let summary: String
    let detail: String
    var state: State = .pending
    var fontSize: CGFloat = 13
    /// A change preview: Apply / Cancel instead of Allow / Allow for Session / Deny.
    var isPreview = false
    let onDecide: (Decision) -> Void
    @SwiftUI.State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundColor(state == .pending ? .orange : ChatTokens.textTertiary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(ChatTokens.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !detail.isEmpty, detail != summary {
                    PanelIconButton(systemName: showDetail ? "chevron.up" : "chevron.down",
                                    help: showDetail ? "Hide details" : "Show details") { showDetail.toggle() }
                        .frame(width: 22, height: 22)
                }
            }
            if !summary.isEmpty {
                Text(showDetail && !detail.isEmpty ? detail : summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ChatTokens.textPrimary)
                    .lineLimit(showDetail || isPreview ? 40 : 3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.25)))
            }
            switch state {
            case .pending:
                HStack(spacing: 6) {
                    if isPreview {
                        Button("Apply") { onDecide(.allow) }
                            .buttonStyle(.borderedProminent)
                        Button("Cancel") { onDecide(.deny) }
                        Spacer(minLength: 0)
                    } else {
                        Button("Allow") { onDecide(.allow) }
                            .buttonStyle(.borderedProminent)
                        Button("Allow for Session") { onDecide(.allowForSession) }
                        Spacer(minLength: 0)
                        Button("Deny", role: .destructive) { onDecide(.deny) }
                    }
                }
                .controlSize(.small)
            case .decided(let label):
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundColor(ChatTokens.textTertiary)
            case .expired:
                Text("No longer needed").font(.system(size: 10.5)).foregroundColor(ChatTokens.textTertiary)
            }
        }
        .chatCard(tint: state == .pending ? .orange : nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval: \(title)")
    }
}

/// Pending outside-agent (MCP) requests, above the composer of any open panel.
struct MCPApprovalStack: View {
    @State private var center = MCPApprovalCenter.shared

    var body: some View {
        if !center.pending.isEmpty {
            VStack(spacing: 6) {
                ForEach(center.pending) { request in
                    PanelApprovalCard(systemImage: request.isPreview ? "slider.horizontal.3" : "person.badge.key",
                                      title: request.title, summary: request.detail, detail: "",
                                      isPreview: request.isPreview) { decision in
                        switch decision {
                        case .allow: center.resolve(request.id, .once)
                        case .allowForSession: center.resolve(request.id, .session)
                        case .deny: center.resolve(request.id, .deny)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}
