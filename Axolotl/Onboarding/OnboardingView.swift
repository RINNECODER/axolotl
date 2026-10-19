import SwiftUI

/// The welcome flow, shown as a sheet over a browser window. Every choice applies as soon as it's
/// made, through the same controls and APIs Settings uses; Esc skips the rest.
struct OnboardingView: View {
    @StateObject private var flow: OnboardingFlow
    let onClose: () -> Void
    @AppStorage(LiquidGlass.defaultsKey) private var glassOn = LiquidGlass.defaultValue

    init(startAt: Int = 0, onClose: @escaping () -> Void) {
        _flow = StateObject(wrappedValue: OnboardingFlow(startAt: startAt))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .id(flow.step)
                .transition(.opacity)
            footer
        }
        .frame(width: 680, height: 700)
        .background(glassOn ? Color.clear : AxolotlSurface.window)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .animation(.easeInOut(duration: 0.18), value: flow.index)
        .onChange(of: flow.isFinished) { _, done in if done { onClose() } }
        .onExitCommand { flow.skipAll() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding")
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                OnboardingProgressDots(count: flow.steps.count, current: flow.index)
                Spacer()
                Button("Skip Setup") { flow.skipAll() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help("Skip the rest (Esc). You can open this again from Help → Show Welcome…")
            }
            Group {
                if flow.step == .welcome {
                    Image(flow.step.symbol).renderingMode(.template).resizable().scaledToFit().padding(11)
                } else {
                    Image(systemName: flow.step.symbol)
                }
            }
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 60, height: 60)
                .axolotlGlass(cornerRadius: 16)
                .padding(.top, 4)
            Text(flow.step.title)
                .font(.system(size: 24, weight: .semibold))
            Text(flow.step.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        Form {
            switch flow.step {
            case .welcome: OnboardingWelcomeStep()
            case .importData: OnboardingImportStep()
            case .ai: OnboardingAIStep()
            case .look: OnboardingLookStep()
            case .privacy: OnboardingPrivacyStep()
            case .developer: OnboardingDevStep()
            }
        }
        .formStyle(.grouped)
        // The settings sections it reuses draw as Form sections here, not settings cards.
        .environment(\.settingsFormHosted, true)
        .scrollContentBackground(.hidden)
        .safeAreaPadding(.top, flow.step == .welcome ? 48 : 0)
        .safeAreaPadding(.bottom, 12)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(AxolotlSurface.stroke).frame(height: 1) }
    }

    private var footer: some View {
        HStack {
            if !flow.isFirst {
                Button("Back") { flow.back() }
            }
            Spacer()
            if !flow.isLast {
                Button("Skip") { flow.skip() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Button(flow.isLast ? "Start Browsing" : "Next") { flow.next() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

/// One dot per step; the current one is a wider pill.
struct OnboardingProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.primary.opacity(i < current ? 0.35 : 0.15))
                    .frame(width: i == current ? 18 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}
