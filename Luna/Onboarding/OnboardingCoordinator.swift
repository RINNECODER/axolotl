import AppKit
import Combine
import Foundation

/// Decides which browser window shows the welcome flow as a sheet. Only one window presents it
/// at a time: the first window at launch, or the most recently active one when asked again.
final class OnboardingCoordinator: ObservableObject {
    static let shared = OnboardingCoordinator()

    @Published private(set) var presenter: UUID?
    /// 0-based step the next presentation opens at.
    @Published private(set) var startStep = 0

    private var windows: [UUID] = []
    private var lastActive: UUID?
    private var launchChecked = false
    /// Welcome was requested while no browser window was open; the next window to appear shows it.
    private var pendingShow = false
    private var observer: AnyCancellable?

    nonisolated deinit {}

    init(center: NotificationCenter = .default) {
        observer = center.publisher(for: .lunaShowOnboarding)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showInActiveWindow() }
    }

    /// Each browser window calls this when it appears; the first one may show the flow (first run).
    func register(window: UUID) {
        if !windows.contains(window) { windows.append(window) }
        if lastActive == nil { lastActive = window }
        if pendingShow {
            pendingShow = false
            launchChecked = true
            present(in: window, at: 0)
            return
        }
        guard !launchChecked else { return }
        launchChecked = true
        if let step = OnboardingState.launchStep() { present(in: window, at: step) }
    }

    func unregister(window: UUID) {
        windows.removeAll { $0 == window }
        if lastActive == window { lastActive = windows.last }
        if presenter == window { presenter = nil }
    }

    func windowBecameActive(_ window: UUID) { lastActive = window }

    func dismiss() { presenter = nil }

    private func showInActiveWindow() {
        guard presenter == nil else { return }
        guard let window = lastActive ?? windows.last else {
            // No browser window: open one (the app's New Window action); it presents the flow when it appears.
            pendingShow = true
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
            return
        }
        present(in: window, at: 0)
    }

    private func present(in window: UUID, at step: Int) {
        startStep = step
        presenter = window
    }
}
