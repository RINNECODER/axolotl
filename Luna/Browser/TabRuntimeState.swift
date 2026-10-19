import Combine
import Foundation
import SwiftUI

/// Volatile per-tab page state: load progress, favicon and audio. Each tab has
/// its own object, so a load-progress step re-renders only the views showing
/// that tab (its strip row, the toolbar when it's active) instead of every view
/// observing `WebViewWrapper`.
final class TabRuntimeState: ObservableObject {
    /// 0…1 in 10% steps while loading; nil when idle.
    @Published fileprivate(set) var loadingProgress: Double?
    @Published fileprivate(set) var faviconURL: URL?
    /// Playing unmuted media.
    @Published fileprivate(set) var isAudible = false

    var isLoading: Bool { loadingProgress != nil }

    /// Stand-in when there is no tab (never changes).
    static let idle = TabRuntimeState()
}

/// Every tab's `TabRuntimeState` for one `WebViewWrapper`. Not forwarded to the
/// wrapper's `objectWillChange`. `revision` changes when any tab's favicon,
/// loading on/off or audio changes (not on progress steps), for views that draw
/// all tabs at once, like the sidebar outline.
final class TabRuntimeStore: ObservableObject {
    @Published private(set) var revision = 0
    private var states: [UUID: TabRuntimeState] = [:]

    func state(for tabId: UUID?) -> TabRuntimeState {
        guard let tabId else { return .idle }
        if let state = states[tabId] { return state }
        let state = TabRuntimeState()
        states[tabId] = state
        return state
    }

    var loadingProgressByTab: [UUID: Double] { states.compactMapValues(\.loadingProgress) }
    var faviconURLByTab: [UUID: URL] { states.compactMapValues(\.faviconURL) }
    var audibleTabs: Set<UUID> { Set(states.filter { $0.value.isAudible }.keys) }

    /// Drops a closed tab's state so it doesn't outlive the tab.
    func remove(_ tabId: UUID) {
        guard states.removeValue(forKey: tabId) != nil else { return }
        revision &+= 1
    }

    func setLoadingProgress(_ progress: Double?, for tabId: UUID) {
        let state = state(for: tabId)
        guard state.loadingProgress != progress else { return }
        let toggled = state.isLoading != (progress != nil)
        state.loadingProgress = progress
        if toggled { revision &+= 1 }
    }

    func setFaviconURL(_ url: URL?, for tabId: UUID) {
        let state = state(for: tabId)
        guard state.faviconURL != url else { return }
        state.faviconURL = url
        revision &+= 1
    }

    func setAudible(_ audible: Bool, for tabId: UUID) {
        let state = state(for: tabId)
        guard state.isAudible != audible else { return }
        state.isAudible = audible
        revision &+= 1
    }
}

/// Re-renders `content` when one tab's runtime state changes, without
/// re-rendering the parent.
struct TabRuntimeReader<Content: View>: View {
    @ObservedObject var state: TabRuntimeState
    @ViewBuilder let content: (TabRuntimeState) -> Content

    var body: some View { content(state) }
}

/// Re-renders `content` when any tab's favicon, loading on/off or audio changes.
struct TabRuntimeRevisionReader<Content: View>: View {
    @ObservedObject var store: TabRuntimeStore
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}
