import Combine
import Foundation
import SwiftUI

/// Volatile per-tab page state: load progress, favicon, audio, zoom, find
/// result, error page and permission prompt. Each tab has
/// its own object, so a load-progress step re-renders only the views showing
/// that tab (its strip row, the toolbar when it's active) instead of every view
/// observing `WebViewWrapper`.
final class TabRuntimeState: ObservableObject {
    /// 0…1 in 10% steps while loading; nil when idle.
    @Published fileprivate(set) var loadingProgress: Double?
    @Published fileprivate(set) var faviconURL: URL?
    /// Playing unmuted media.
    @Published fileprivate(set) var isAudible = false
    /// 1.0 = 100%.
    @Published fileprivate(set) var zoom: CGFloat = 1
    /// Find-bar match count ("3 of 17"), set by FindInPage.
    @Published fileprivate(set) var findResult: FindInPage.Result?
    /// Axolotl's native error page (failed load or crashed web process).
    @Published fileprivate(set) var pageError: PageError?
    /// Camera / microphone / location prompt waiting for the user.
    @Published fileprivate(set) var pendingPermission: SitePermissionRequest?

    /// Page looks like an article (reader button shown).
    @Published fileprivate(set) var isReaderable = false
    /// Article being shown in Reader, if any.
    @Published fileprivate(set) var readerArticle: ReaderMode.Article?

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
    var findResultByTab: [UUID: FindInPage.Result] { states.compactMapValues(\.findResult) }
    var pageErrorByTab: [UUID: PageError] { states.compactMapValues(\.pageError) }
    var pendingPermissions: [UUID: SitePermissionRequest] { states.compactMapValues(\.pendingPermission) }

    var readerableTabs: Set<UUID> { Set(states.filter { $0.value.isReaderable }.keys) }
    var readerArticleByTab: [UUID: ReaderMode.Article] { states.compactMapValues(\.readerArticle) }

    func setReaderable(_ on: Bool, for tabId: UUID) { set(\.isReaderable, on, for: tabId) }
    func setReaderArticle(_ article: ReaderMode.Article?, for tabId: UUID) {
        let state = state(for: tabId)
        if state.readerArticle != nil || article != nil { state.readerArticle = article }
    }

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

    func setZoom(_ zoom: CGFloat, for tabId: UUID) { set(\.zoom, zoom, for: tabId) }
    func setFindResult(_ result: FindInPage.Result?, for tabId: UUID) { set(\.findResult, result, for: tabId) }
    func setPageError(_ error: PageError?, for tabId: UUID) { set(\.pageError, error, for: tabId) }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<TabRuntimeState, Value>, _ value: Value, for tabId: UUID) {
        let state = state(for: tabId)
        if state[keyPath: keyPath] != value { state[keyPath: keyPath] = value }
    }

    /// Replaces the tab's permission prompt and returns the one it replaced.
    @discardableResult
    func setPendingPermission(_ request: SitePermissionRequest?, for tabId: UUID) -> SitePermissionRequest? {
        let state = state(for: tabId)
        let old = state.pendingPermission
        if old !== request { state.pendingPermission = request }
        return old
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

/// Re-renders `content` when `object` changes, without re-rendering the parent.
struct ObservedReader<Object: ObservableObject, Content: View>: View {
    @ObservedObject var object: Object
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

/// Re-renders `content` when any tab's favicon, loading on/off or audio changes.
struct TabRuntimeRevisionReader<Content: View>: View {
    @ObservedObject var store: TabRuntimeStore
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}
