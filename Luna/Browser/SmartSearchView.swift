// Luma — SmartSearch: full-viewport new tab page with intent classification
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

// MARK: - State machine

private enum SearchViewState: Equatable {
    case idle
    case aiChat
    case searching
}

// MARK: - SmartSearchView

struct SmartSearchView: View {
    let gemini: GeminiClient
    let ollama: OllamaClient
    let tabManager: TabManager
    let webViewWrapper: WebViewWrapper
    var tabId: UUID?
    @Binding var messages: [ChatMessage]
    let onNavigate: (URL) -> Void
    /// The address bar's bookmark / history / open-tab rows for a query, and how to open one,
    /// so this box suggests pages like Chrome's new-tab box.
    var urlSuggestions: ((String) async -> [AddressSuggestion])? = nil
    var onOpenURLSuggestion: ((AddressSuggestion) -> Void)? = nil

    @AppStorage("luma_ai_provider")    private var aiProviderRaw: String = AIProvider.gemini.rawValue
    @AppStorage("luma_ollama_base_url") private var ollamaBaseURL: String = "http://127.0.0.1:11434"
    @AppStorage("luma_ollama_model")    private var ollamaModel: String = ""
    @AppStorage("luma_ai_panel_font_size") private var fontSizeRaw: Int = 13
    @AppStorage("luma_search_suggestions_enabled") private var searchSuggestionsEnabled: Bool = false
    @AppStorage(StartPagePrefs.showShortcuts) private var showShortcuts = true
    @ObservedObject private var wallpaper = WallpaperStore.shared

    @Environment(\.isPrivateBrowsing) private var isPrivate
    @State private var viewState: SearchViewState = .idle
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String? = nil
    @FocusState private var isInputFocused: Bool

    @State private var hasGeneratedTitle: Bool = false
    @State private var searchBarOffset: CGFloat = 0
    @State private var previousInputLength: Int = 0
    @State private var currentIntent: QueryIntent = .search
    /// True while an ambiguous query is being routed by the model.
    @State private var isRouting: Bool = false
    @State private var streamingTask: Task<Void, Never>? = nil

    // Thinking steps
    @State private var thinkingSteps: [SmartThinkingStep] = []
    @State private var isThinking: Bool = false
    @State private var currentAITask: Task<Void, Never>? = nil
    /// Incremented whenever a stream starts or is cancelled; stale callbacks compare
    /// their captured generation against this and bail out.
    @State private var streamGeneration: Int = 0

    // Suggestions
    @State private var searchSuggestions: [String] = []
    @State private var urlRows: [AddressSuggestion] = []
    @State private var selectedSuggestionIndex: Int = -1
    @State private var suggestionDebounceTask: DispatchWorkItem? = nil
    @State private var suggestionKeyMonitor: Any? = nil

    // Find bar
    @State private var showFindBar: Bool = false
    @State private var findQuery: String = ""
    @FocusState private var isFindFocused: Bool

    // Context system
    @State private var attachedDocuments: [SmartAttachedDocument] = []
    @State private var documentPickerPresented: Bool = false
    @State private var documentError: String? = nil
    @State private var includedOtherTabIds: [UUID] = []
    @State private var otherTabContexts: [UUID: (title: String?, text: String?)] = [:]
    @State private var addContextFromCard: Bool = false
    @State private var addContextFromChat: Bool = false

    private var aiProvider: AIProvider { AIProvider(rawValue: aiProviderRaw) ?? .gemini }
    private var fontSize: CGFloat { CGFloat(fontSizeRaw) }

    var body: some View {
        ZStack {
            background

            switch viewState {
            case .idle:
                centeredBarLayout
            case .aiChat:
                chatLayout
            case .searching:
                EmptyView()
            }
        }
        // The start page is dark glass in both appearances.
        .environment(\.colorScheme, .dark)
        .onAppear {
            if !messages.isEmpty {
                viewState = .aiChat
            }
            isInputFocused = true
            installSuggestionKeyMonitor()
        }
        .onDisappear {
            removeSuggestionKeyMonitor()
            // The tab may navigate away mid-generation; cancel so orphaned
            // tasks don't keep running and mutating the messages binding.
            streamGeneration += 1
            currentAITask?.cancel()
            currentAITask = nil
            streamingTask?.cancel()
            streamingTask = nil
            isSending = false
            isThinking = false
        }
        .fileImporter(
            isPresented: $documentPickerPresented,
            allowedContentTypes: [UTType.pdf, .plainText, .utf8PlainText, .commaSeparatedText, .xml, .html],
            allowsMultipleSelection: true
        ) { result in
            documentError = nil
            switch result {
            case .success(let urls):
                for url in urls {
                    addDocument(from: url, securityScoped: true)
                }
            case .failure(let error):
                documentError = error.localizedDescription
            }
        }
        .background(
            Button("") {
                withAnimation(.easeOut(duration: 0.15)) {
                    showFindBar.toggle()
                    if showFindBar { isFindFocused = true }
                    else { findQuery = "" }
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        )
    }

    // MARK: - Background

    /// Native macOS surface: under-window material with a near-opaque dark wash,
    /// like Notes/Music/Xcode. Depth comes from the material, not from color.
    private var background: some View {
        ZStack {
            StartPageBackdrop()
            if wallpaper.preset != .none {
                WallpaperView(config: wallpaper.renderConfig(still: false))
                wallpaperScrim
            }
        }
        .ignoresSafeArea()
    }

    /// Keeps the greeting and search bar legible over any wallpaper: an even dim
    /// the user controls, plus a soft darkening behind the centered content.
    private var wallpaperScrim: some View {
        let dim = wallpaper.style(for: wallpaper.preset).dim
        return ZStack {
            Color.black.opacity(dim)
            RadialGradient(colors: [Color.black.opacity(0.28), .clear],
                           center: .center, startRadius: 0, endRadius: 520)
        }
        .allowsHitTesting(false)
    }

    /// The moon always shows without a wallpaper; with one, it's the user's call.
    private var showsMoon: Bool { wallpaper.preset == .none || wallpaper.showMoon }

    // MARK: - Centered bar (idle)

    private var centeredBarLayout: some View {
        GeometryReader { geo in
            let h = geo.size.height
            // Moon shrinks with the window and drops out when there's no room.
            let moon = showsMoon ? min(170, (h - 330) * 0.5) : 0
            // With the moon showing, lift it into the top margin and give it a
            // clear gap above the greeting; the search field stays put.
            let moonLift: CGFloat = moon >= 64 ? 12 : 0
            let topOffset = max(16, h * 0.09) - moonLift
            ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if moon >= 64 {
                    Group {
                        if wallpaper.moonStyle == .shader {
                            ShaderMoon(diameter: moon, isBusy: isRouting)
                        } else {
                            AsciiMoon(diameter: moon, isBusy: isRouting)
                        }
                    }
                        .padding(.bottom, moonLift - 6)
                }
                // Quiet greeting above the bar (Siri / ChatGPT-app style)
                Text(Self.greeting())
                    .font(LunaType.brand(size: 30))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .padding(.bottom, 28)
                    .accessibilityHidden(true)

                // Context chips above the bar
                if !includedOtherTabIds.isEmpty || !attachedDocuments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(includedOtherTabIds, id: \.self) { otherId in
                                ContextChip(
                                    kind: .tab(url: tabManager.tabURL[otherId] ?? nil, faviconURL: webViewWrapper.faviconURLByTab[otherId] ?? nil),
                                    title: otherTabLabel(tabId: otherId),
                                    onRemove: { removeIncludedOtherTab(id: otherId) }
                                )
                            }
                            ForEach(attachedDocuments) { doc in
                                ContextChip(
                                    kind: .document(filename: doc.displayName),
                                    title: doc.displayName,
                                    onRemove: { removeAttachedDocument(id: doc.id) }
                                )
                            }
                        }
                    }
                    .frame(maxWidth: ChatTokens.barMaxWidth)
                    .padding(.bottom, 8)
                }

                unifiedSearchCard
                    .frame(maxWidth: ChatTokens.barMaxWidth)

                if inputText.isEmpty && showShortcuts {
                    StartShortcutsRow(onOpen: onNavigate)
                        .frame(maxWidth: ChatTokens.barMaxWidth)
                        .padding(.top, 28)
                        .transition(.opacity)
                }
                if inputText.isEmpty {
                    ShieldsStatLine(counter: webViewWrapper.shieldsCounter)
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, max(12, min(32, geo.size.width * 0.04)))
            .padding(.top, topOffset + searchBarOffset)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .transition(.opacity)
    }

    // MARK: - AI Chat layout

    private var chatLayout: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                chatThread
                if showFindBar { findBar }
            }
            chatInputBar
        }
        .transition(.opacity)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(ChatTokens.textTertiary)
            TextField("Find in conversation\u{2026}", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(ChatTokens.textPrimary)
                .focused($isFindFocused)
                .onSubmit { scrollToNextMatch() }
            Text(findMatchSummary)
                .font(.system(size: 11))
                .foregroundColor(ChatTokens.textTertiary)
                .layoutPriority(1)
            Button(action: { scrollToNextMatch() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ChatTokens.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: closeFindBar) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ChatTokens.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            LunaMaterialFill(shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
                             material: .ultraThinMaterial, solid: Color(lunaHex: 0x232326), strokesWhenSolid: false,
                             surface: .startPage)
        )
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var findMatchSummary: String {
        guard !findQuery.isEmpty else { return "" }
        let lower = findQuery.lowercased()
        let count = messages.filter { $0.text.lowercased().contains(lower) }.count
        return count == 0 ? "No matches" : "\(count) match\(count == 1 ? "" : "es")"
    }

    @State private var findScrollTarget: UUID? = nil

    private func scrollToNextMatch() {
        guard !findQuery.isEmpty else { return }
        let lower = findQuery.lowercased()
        let matching = messages.filter { $0.text.lowercased().contains(lower) }
        guard !matching.isEmpty else { return }

        if let current = findScrollTarget,
           let idx = matching.firstIndex(where: { $0.id == current }),
           idx + 1 < matching.count {
            findScrollTarget = matching[idx + 1].id
        } else {
            findScrollTarget = matching.first?.id
        }
    }

    private func closeFindBar() {
        withAnimation(.easeOut(duration: 0.15)) {
            showFindBar = false
            findQuery = ""
            findScrollTarget = nil
        }
    }

    private var chatThread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                        let isMatch = !findQuery.isEmpty &&
                            msg.text.lowercased().contains(findQuery.lowercased())
                        LunaChatBubble(
                            message: msg,
                            isUser: msg.role == .user,
                            fontSize: fontSize,
                            onRetry: msg.role == .assistant ? { retryResponse(at: index) } : nil,
                            onEdit: msg.role == .user ? { editMessage(at: index) } : nil,
                            onLinkTapped: { url in openLinkInNewTab(url) }
                        )
                        .id(msg.id)
                        .frame(maxWidth: ChatTokens.chatMaxWidth,
                               alignment: msg.role == .user ? .trailing : .leading)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(ChatTokens.accent.opacity(isMatch ? 0.6 : 0), lineWidth: 1.5)
                                .padding(-4)
                        )
                        .animation(.easeInOut(duration: 0.2), value: isMatch)
                    }
                    if isThinking || isSending { thinkingStepsView }
                    if let err = errorMessage { errorBanner(err) }
                }
                .frame(maxWidth: ChatTokens.chatMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: findScrollTarget) { _, target in
                if let target = target {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
    }

    private var thinkingStepsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(thinkingSteps) { step in
                ChatThinkingRow(text: step.text, isComplete: step.isComplete, fontSize: fontSize)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isSending && thinkingSteps.allSatisfy({ $0.isComplete }) {
                LunaSayingRow(fontSize: fontSize)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: ChatTokens.chatMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: thinkingSteps.count)
    }

    private func errorBanner(_ message: String) -> some View {
        ChatErrorBanner(message: message, fontSize: fontSize)
    }

    /// "+" popover: toggle open tabs as context, or choose files.
    private func addContextPopover(dismiss: @escaping () -> Void) -> some View {
        AddContextPopover(
            tabs: tabManager.tabOrder.filter { $0 != tabId }.compactMap { id in
                guard let url = tabManager.tabURL[id] ?? nil, url.scheme?.hasPrefix("http") == true else { return nil }
                return AddContextPopover.TabItem(id: id, title: otherTabLabel(tabId: id), url: url,
                                                 faviconURL: webViewWrapper.faviconURLByTab[id] ?? nil)
            },
            included: Set(includedOtherTabIds),
            onToggleTab: { id in
                if includedOtherTabIds.contains(id) {
                    removeIncludedOtherTab(id: id)
                } else {
                    includedOtherTabIds.append(id)
                    loadTabContext(for: id)
                    if viewState == .idle { enterChatWithContext() }
                }
            },
            onChooseFiles: {
                dismiss()
                documentPickerPresented = true
            }
        )
        // The start page is always dark glass; the popover follows the system.
        .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
    }

    private var chatInputBar: some View {
        return VStack(spacing: 0) {
            // Context chips row
            if !includedOtherTabIds.isEmpty || !attachedDocuments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(includedOtherTabIds, id: \.self) { otherId in
                            ContextChip(
                                kind: .tab(url: tabManager.tabURL[otherId] ?? nil, faviconURL: webViewWrapper.faviconURLByTab[otherId] ?? nil),
                                title: otherTabLabel(tabId: otherId),
                                onRemove: { removeIncludedOtherTab(id: otherId) }
                            )
                        }
                        ForEach(attachedDocuments) { doc in
                            ContextChip(
                                kind: .document(filename: doc.displayName),
                                title: doc.displayName,
                                onRemove: { removeAttachedDocument(id: doc.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 32)
                .frame(maxWidth: ChatTokens.chatMaxWidth)
                .padding(.bottom, 6)
            }

            HStack(alignment: .bottom, spacing: 0) {
                ChatAddContextButton(isActive: addContextFromChat) { addContextFromChat.toggle() }
                .lunaPopover(isPresented: $addContextFromChat, arrowEdge: .top) { addContextPopover(dismiss: { addContextFromChat = false }) }
                .padding(.bottom, 3)

                SmartGrowingInput(
                    text: $inputText,
                    placeholder: "Follow up\u{2026}",
                    fontSize: fontSize,
                    isFocused: $isInputFocused,
                    onSubmit: sendChatMessage,
                    onLargePaste: { pastedText in
                        let filename = "\(UUID().uuidString.prefix(8)).txt"
                        attachedDocuments.append(SmartAttachedDocument(
                            displayName: filename,
                            extractedText: pastedText
                        ))
                    }
                )
                .frame(maxWidth: .infinity)

                ChatSendStopButton(
                    isSending: isSending,
                    canSend: !inputText.isEmpty,
                    onSend: sendChatMessage,
                    onStop: stopGenerating
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: ChatTokens.chatMaxWidth)
            .lunaGlass(cornerRadius: 22, interactive: true, surface: .startPage)
            .focusShadow(isInputFocused)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 20)
    }

    // MARK: - Unified search card (Dia-style two-row layout)

    private var unifiedSearchCard: some View {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(spacing: 0) {
            // Row 1: icon + text field
            HStack(spacing: 8) {
                Image(systemName: currentIntent == .ai ? "bubble.left.fill" : "magnifyingglass")
                    .background(
                        // ⌘↩ always opens chat, whatever the router thinks.
                        Button("") { forceChat() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .hidden()
                    )
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(ChatTokens.textTertiary)
                    .frame(width: 20)
                    .animation(.easeInOut(duration: 0.15), value: currentIntent)

                TextField("Ask anything\u{2026}", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundColor(ChatTokens.textPrimary)
                    .focused($isInputFocused)
                    .onSubmit { submitWithSelection() }
                    .onChange(of: inputText) { _, newValue in
                        selectedSuggestionIndex = -1
                        fetchSuggestions(for: newValue)
                        handlePasteDetection(newValue)
                        let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        let hasContext = !attachedDocuments.isEmpty || !includedOtherTabIds.isEmpty
                        currentIntent = t.isEmpty ? .search : (hasContext ? .ai : QueryClassifier.classify(t))
                    }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Inline suggestions (between rows)
            if viewState == .idle && !trimmed.isEmpty && isInputFocused {
                OmniboxDropdown(rows: suggestionRows, query: trimmed, selectedIndex: selectedSuggestionIndex,
                                drawsSurface: false, onSelect: applySuggestion)
            }

            // Divider when suggestions are showing
            if viewState == .idle && !trimmed.isEmpty && isInputFocused {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
            }

            // Row 2: action pills + submit
            HStack(spacing: 8) {
                Button { addContextFromCard.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Add tabs or files")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(ChatTokens.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(addContextFromCard ? 0.1 : 0)))
                    .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .lunaPopover(isPresented: $addContextFromCard, arrowEdge: .bottom) { addContextPopover(dismiss: { addContextFromCard = false }) }

                Spacer()

                // Dynamic submit button
                submitButton(trimmed: trimmed)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .lunaGlass(cornerRadius: 22, interactive: true, surface: .startPage)
        .focusShadow(isInputFocused)
    }

    // MARK: - Dynamic submit button

    @ViewBuilder
    private func submitButton(trimmed: String) -> some View {
        if trimmed.isEmpty {
            Button(action: { submitWithSelection() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Color.white.opacity(0.15))
            }
            .buttonStyle(.plain)
            .disabled(true)
        } else {
            Button(action: { submitWithSelection() }) {
                HStack(spacing: 4) {
                    if isRouting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(currentIntent == .ai ? "Chat" : "Google")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .foregroundColor(Color.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.92))
                )
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .animation(.easeOut(duration: 0.15), value: currentIntent)
        }
    }

    // MARK: - Inline suggestions

    private var hasSuggestions: Bool {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    /// The address bar's rows plus "Ask Luna" (Chrome omnibox order, at most 6).
    private var suggestionRows: [OmniboxRow] {
        Omnibox.rows(typed: inputText, pages: urlRows, phrases: searchSuggestions, chat: true)
    }

    /// Time-of-day greeting for the start page.
    private static func greeting() -> String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good Morning"
        case 12..<17: return "Good Afternoon"
        case 17..<22: return "Good Evening"
        default: return "Up Late?"
        }
    }

    private func applySuggestion(_ row: OmniboxRow) {
        clearSuggestions()
        switch row.kind {
        case .chat: transitionToChat()
        case .typedSearch(let q): performSearch(q)
        case .typedURL(_, let url):
            withAnimation(.easeOut(duration: 0.15)) { viewState = .searching }
            onNavigate(url)
        case .search(let text):
            inputText = text
            performSearch(text)
        case .page(let page): onOpenURLSuggestion?(page)
        }
    }

    private func submitWithSelection() {
        let rows = suggestionRows
        if selectedSuggestionIndex >= 0, selectedSuggestionIndex < rows.count {
            applySuggestion(rows[selectedSuggestionIndex])
        } else {
            handleSubmit()
        }
    }

    private func fetchSuggestions(for query: String) {
        suggestionDebounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { urlRows = [] }
        let wantsPhrases = searchSuggestionsEnabled && trimmed.count >= 2
        if !wantsPhrases { searchSuggestions = [] }
        guard !trimmed.isEmpty, wantsPhrases || urlSuggestions != nil else { return }

        let work = DispatchWorkItem { [trimmed] in
            if let urlSuggestions {
                Task {
                    let rows = await urlSuggestions(trimmed)
                    // A newer keystroke makes this answer stale.
                    if inputText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed { urlRows = rows }
                }
            }
            guard wantsPhrases, let url = SearchEngine.suggestEngine?.suggestURL(for: trimmed) else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            (isPrivate ? PrivateBrowsing.urlSession : URLSession.shared).dataTask(with: request) { data, _, _ in
                let phrases = SearchEngine.parseSuggestions(data) ?? []
                DispatchQueue.main.async {
                    // A newer keystroke makes this answer (or failure) stale.
                    guard inputText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                    searchSuggestions = Array(phrases.prefix(8))
                }
            }.resume()
        }
        suggestionDebounceTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func handlePasteDetection(_ newValue: String) {
        let delta = newValue.count - previousInputLength
        previousInputLength = newValue.count

        // Large jump in length (>300 chars in a single frame) = likely a paste
        if delta > 300 {
            let pastedText = newValue
            inputText = ""
            previousInputLength = 0

            let filename = "\(UUID().uuidString.prefix(8)).txt"
            attachedDocuments.append(SmartAttachedDocument(
                displayName: filename,
                extractedText: pastedText
            ))

            if viewState == .idle {
                enterChatWithContext()
            }
        }
    }

    private func clearSuggestions() {
        searchSuggestions = []
        urlRows = []
        selectedSuggestionIndex = -1
    }

    private func installSuggestionKeyMonitor() {
        guard suggestionKeyMonitor == nil else { return }
        suggestionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors are app-wide: with multiple windows, only the key
            // window's start page should steal arrow keys.
            guard event.window === NSApp.keyWindow else { return event }
            guard viewState == .idle, hasSuggestions, isInputFocused else { return event }
            let rows = suggestionRows
            guard !rows.isEmpty else { return event }

            if event.keyCode == 125 { // Down arrow
                DispatchQueue.main.async {
                    selectedSuggestionIndex = min(selectedSuggestionIndex + 1, rows.count - 1)
                }
                return nil
            }
            if event.keyCode == 126 { // Up arrow
                DispatchQueue.main.async {
                    selectedSuggestionIndex = max(-1, selectedSuggestionIndex - 1)
                }
                return nil
            }
            return event
        }
    }

    private func removeSuggestionKeyMonitor() {
        if let monitor = suggestionKeyMonitor {
            NSEvent.removeMonitor(monitor)
            suggestionKeyMonitor = nil
        }
    }

    // MARK: - Actions

    private func handleSubmit() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard viewState == .idle else { return }

        if let url = resolveAsURL(trimmed) {
            onNavigate(url)
            return
        }

        // If context is attached, always go to AI chat
        let hasContext = !attachedDocuments.isEmpty || !includedOtherTabIds.isEmpty
        if hasContext {
            transitionToChat()
            return
        }

        // Google first: heuristics settle clear cases instantly; ambiguous
        // ones are routed by the model (search on timeout or failure).
        switch QueryClassifier.verdict(trimmed) {
        case .search:
            performSearch(trimmed)
        case .ai:
            transitionToChat()
        case .unsure:
            guard !isRouting else { return }
            // Private windows never send typed text to a cloud model just to route it.
            if isPrivate && LLMService.shared.provider != .ollama {
                performSearch(trimmed)
                return
            }
            isRouting = true
            Task { @MainActor in
                let intent = await QueryClassifier.resolve(trimmed)
                isRouting = false
                // Ignore the answer if the user changed or cleared the input meanwhile.
                guard viewState == .idle,
                      inputText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                currentIntent = intent
                if intent == .ai { transitionToChat() } else { performSearch(trimmed) }
            }
        }
    }

    /// ⌘↩: open chat regardless of routing.
    private func forceChat() {
        guard viewState == .idle, !isRouting,
              !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearSuggestions()
        transitionToChat()
    }

    private func stopGenerating() {
        // Invalidate the generation so late onToken/onCompletion callbacks
        // from the cancelled task are ignored.
        streamGeneration += 1
        currentAITask?.cancel()
        currentAITask = nil
        streamingTask?.cancel()
        streamingTask = nil
        withAnimation(.easeOut(duration: 0.2)) {
            thinkingSteps = []
            isThinking = false
        }
        isSending = false
        // Append a stop notice to partial assistant message if any
        if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
            if !messages[lastIdx].text.isEmpty {
                messages[lastIdx].status = "Generation stopped"
            } else {
                messages.removeLast()
            }
        }
    }

    // MARK: - URL detection + typo correction

    private func resolveAsURL(_ input: String) -> URL? {
        // Keep the original case: URL paths are case-sensitive (e.g. GitHub Pages /Luna/).
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: trimmed)
        }

        let tlds: Set<String> = [
            "com", "org", "net", "edu", "gov", "io", "co", "app", "dev",
            "me", "tv", "ai", "xyz", "info", "biz", "us", "uk", "ca",
            "de", "fr", "jp", "au", "in", "br", "it", "nl", "ru", "ch"
        ]
        let parts = lower.components(separatedBy: ".")
        if parts.count >= 2, let lastPart = parts.last {
            let tldCandidate = lastPart.components(separatedBy: "/").first ?? lastPart
            if tlds.contains(tldCandidate) {
                let corrected = correctURLTypos(trimmed)
                return URL(string: "https://\(corrected)")
            }
        }
        return nil
    }

    private func correctURLTypos(_ input: String) -> String {
        let corrections: [String: String] = [
            "yuotube": "youtube", "yotube": "youtube", "youtbe": "youtube",
            "youube": "youtube", "yotuube": "youtube", "youttube": "youtube",
            "gogle": "google", "goggle": "google", "gooogle": "google",
            "googlr": "google", "googel": "google", "googe": "google",
            "twtter": "twitter", "twiter": "twitter", "tiwtter": "twitter",
            "facebok": "facebook", "facbook": "facebook", "fcebook": "facebook",
            "faecbook": "facebook", "faceboo": "facebook",
            "instagra": "instagram", "instagarm": "instagram",
            "instragram": "instagram", "instagrm": "instagram",
            "linkdin": "linkedin", "linkeind": "linkedin", "linkeidn": "linkedin",
            "redit": "reddit", "rediit": "reddit", "reddti": "reddit",
            "amazo": "amazon", "amzon": "amazon", "amaozn": "amazon",
            "netfilx": "netflix", "netfli": "netflix", "netflx": "netflix",
            "spotfiy": "spotify", "sptoify": "spotify", "spotiy": "spotify",
            "wikpedia": "wikipedia", "wikipdia": "wikipedia", "wikipeida": "wikipedia",
            "githu": "github", "gihub": "github", "githb": "github",
            "githbu": "github", "gihtub": "github",
            "stackovreflow": "stackoverflow", "stackoverlfow": "stackoverflow",
            "stakoverflow": "stackoverflow",
            "chatgtp": "chatgpt", "chatgp": "chatgpt",
            "discrod": "discord", "disocrd": "discord",
            "tiktk": "tiktok", "tikto": "tiktok",
            "pinterst": "pinterest", "pintrest": "pinterest",
            "tumblr": "tumblr", "tumbrl": "tumblr",
            "dcos": "docs", "dcso": "docs"
        ]

        var result = input
        let dotIndex = result.firstIndex(of: ".") ?? result.endIndex
        let domainPart = String(result[result.startIndex..<dotIndex])
        let rest = String(result[dotIndex...])

        if let corrected = corrections[domainPart.lowercased()] {
            result = corrected + rest
        }
        return result
    }

    private func performSearch(_ query: String) {
        withAnimation(.easeOut(duration: 0.15)) { viewState = .searching }
        if let url = SearchEngine.url(searching: query) {
            onNavigate(url)
        }
    }

    private func transitionToChat() {
        let firstMessage = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstMessage.isEmpty else { return }

        messages.append(ChatMessage(role: .user, text: firstMessage))
        inputText = ""

        if let id = tabId {
            let aiURL = URL(string: "luma://ai/\(id.uuidString)")!
            tabManager.navigate(tab: id, to: aiURL)
            tabManager.updateTitle(tab: id, title: heuristicTitle(firstMessage))
        }

        // Slide the search bar down before switching to chat layout
        withAnimation(.easeIn(duration: 0.18)) {
            searchBarOffset = 80
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            searchBarOffset = 0
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                viewState = .aiChat
            }
        }

        sendAIRequest(prompt: firstMessage, isFirstMessage: true)
    }

    private func sendChatMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }

        let isFirst = messages.isEmpty
        messages.append(ChatMessage(role: .user, text: trimmed))
        inputText = ""
        sendAIRequest(prompt: trimmed, isFirstMessage: isFirst)
    }

    private func sendAIRequest(prompt: String, isFirstMessage: Bool = false) {
        isSending = true
        isThinking = true
        errorMessage = nil
        thinkingSteps = []

        let capturedQuery = isFirstMessage ? prompt : nil
        let needsWebSearch = Self.shouldWebSearch(prompt)
        let detectedURLs = Self.extractURLs(from: prompt)

        let task = Task {
            // Step 0: fetch any URLs the user pasted
            var linkContext: String? = nil
            if !detectedURLs.isEmpty {
                addThinkingStep("Reading \(detectedURLs.count == 1 ? "link" : "\(detectedURLs.count) links")\u{2026}")
                var fetched: [WebSource] = []
                for url in detectedURLs.prefix(3) {
                    guard !Task.isCancelled else { return }
                    if let source = await WebSearchService.fetchSingleURL(url) { fetched.append(source) }
                }
                guard !Task.isCancelled else { return }
                if !fetched.isEmpty { linkContext = WebSearchService.formatSourcesAsContext(fetched) }
                completeLastThinkingStep()
            }

            // Step 1: optional web search
            var webContext: String? = nil
            if needsWebSearch && detectedURLs.isEmpty {
                addThinkingStep("Searching the web\u{2026}")
                do {
                    let sources = try await WebSearchService.searchAndFetch(query: prompt, maxResults: 4)
                    guard !Task.isCancelled else { return }
                    if !sources.isEmpty {
                        completeLastThinkingStep()
                        addThinkingStep("Reading \(sources.count) source\(sources.count == 1 ? "" : "s")\u{2026}")
                        webContext = WebSearchService.formatSourcesAsContext(sources)
                        completeLastThinkingStep()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    completeLastThinkingStep()
                }
            }

            guard !Task.isCancelled else { return }
            addThinkingStep("Thinking\u{2026}")

            let recentContext = Array(messages.dropLast().suffix(6))
            var contextParts: [String] = []
            if let userCtx = buildContextString() { contextParts.append(userCtx) }
            if let link = linkContext { contextParts.append(link) }
            if let web = webContext { contextParts.append(web) }
            let finalContext = contextParts.isEmpty ? nil : contextParts.joined(separator: "\n\n")

            guard !Task.isCancelled else { return }

            // Dismiss thinking steps and begin streaming.
            // Track the assistant message by stable id (not index) and by
            // generation, so Stop/resend can't corrupt the wrong message.
            let placeholderId = UUID()
            let generation = await MainActor.run { () -> Int in
                withAnimation(.easeOut(duration: 0.3)) {
                    thinkingSteps = []
                    isThinking = false
                }
                messages.append(ChatMessage(id: placeholderId, role: .assistant, text: ""))
                streamGeneration += 1
                return streamGeneration
            }

            if let query = capturedQuery {
                await MainActor.run { generateAITitle(for: query) }
            }

            let onToken: @Sendable (String) -> Void = { token in
                Task { @MainActor in
                    guard generation == streamGeneration,
                          let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
                    messages[idx].text += token
                }
            }

            let onCompletion: @Sendable (Result<Void, Error>) -> Void = { result in
                Task { @MainActor in
                    guard generation == streamGeneration else { return }
                    streamingTask = nil
                    isSending = false
                    switch result {
                    case .success: break
                    case .failure(let error):
                        let msg = error.localizedDescription
                        errorMessage = msg
                        if let idx = messages.firstIndex(where: { $0.id == placeholderId }) {
                            messages[idx].status = "Error: \(msg)"
                        }
                    }
                }
            }

            await MainActor.run {
                // Stop may land while the title request awaited; don't start an orphaned stream.
                guard generation == streamGeneration, !Task.isCancelled else { return }
                streamingTask = LLMService.shared.stream(
                    LLMRequest(prompt: prompt, context: finalContext, recentMessages: recentContext),
                    onToken: onToken,
                    onCompletion: onCompletion
                )
            }
        }
        currentAITask = task
    }

    private static func extractURLs(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { match -> URL? in
            guard let range = Range(match.range, in: text) else { return nil }
            let urlStr = String(text[range])
            return URL(string: urlStr)
        }
    }

    private static func shouldWebSearch(_ query: String) -> Bool {
        let lower = query.lowercased()
        let words = lower.split(separator: " ").map(String.init)

        let webSearchTriggers = [
            "latest", "current", "recent", "today", "tonight", "yesterday",
            "this week", "this month", "this year", "news", "score", "scores",
            "price", "cost", "weather", "stock", "release date", "how much",
            "when does", "when did", "when is", "when will", "who won",
            "who is the", "what happened", "right now", "live",
            "results", "standings", "schedule", "stats", "statistics",
            "reviews", "rating", "ratings", "compare prices", "best deals",
            "where to buy", "hours", "open now", "near me", "directions",
            "election", "earnings", "box office", "trailer", "announced"
        ]
        for trigger in webSearchTriggers {
            if lower.contains(trigger) { return true }
        }

        let yearPattern = try? NSRegularExpression(pattern: "\\b20[2-3]\\d\\b")
        if let regex = yearPattern,
           regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
            return true
        }

        let noSearchVerbs: Set<String> = [
            "write", "create", "make", "draft", "compose", "generate",
            "rewrite", "help", "explain", "teach", "describe", "summarize",
            "analyze", "debug", "fix", "refactor", "optimize", "convert",
            "brainstorm", "plan", "outline", "simplify", "elaborate"
        ]
        if let first = words.first, noSearchVerbs.contains(first) {
            return false
        }

        let noSearchPhrases = [
            "how do i", "how to", "what is the difference",
            "give me ideas", "help me", "can you", "could you",
            "tell me about", "what should i", "why do i",
            "pros and cons", "step by step"
        ]
        for phrase in noSearchPhrases {
            if lower.contains(phrase) { return false }
        }

        return false
    }

    private func addThinkingStep(_ text: String) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                thinkingSteps.append(SmartThinkingStep(text: text))
            }
        }
    }

    private func completeLastThinkingStep() {
        DispatchQueue.main.async {
            guard !thinkingSteps.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                thinkingSteps[thinkingSteps.count - 1].isComplete = true
            }
        }
    }

    // MARK: - Retry / Edit

    private func retryResponse(at index: Int) {
        guard index < messages.count, messages[index].role == .assistant else { return }
        guard !isSending else { return }

        let userIndex = index - 1
        guard userIndex >= 0, messages[userIndex].role == .user else { return }
        let userPrompt = messages[userIndex].text

        messages.removeSubrange(index...)
        sendAIRequest(prompt: userPrompt)
    }

    private func editMessage(at index: Int) {
        guard index < messages.count, messages[index].role == .user else { return }

        inputText = messages[index].text
        messages.removeSubrange(index...)
        isInputFocused = true
    }

    // MARK: - Tab title

    private func heuristicTitle(_ query: String) -> String {
        let maxLen = 25
        if query.count <= maxLen { return query }
        let prefix = String(query.prefix(maxLen))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "\u{2026}"
        }
        return prefix + "\u{2026}"
    }

    private func generateAITitle(for query: String) {
        guard !hasGeneratedTitle, let id = tabId else { return }
        hasGeneratedTitle = true

        let titlePrompt = "Generate a 2-5 word tab title for this conversation. First message: \"\(query)\". Reply with ONLY the title, no quotes, no punctuation."

        LLMService.shared.complete(LLMRequest(prompt: titlePrompt)) { result in
            DispatchQueue.main.async {
                if case .success(let raw) = result {
                    let title = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
                    if !title.isEmpty && title.count < 40 {
                        tabManager.updateTitle(tab: id, title: title)
                    }
                }
            }
        }
    }

    // MARK: - Link handling

    private func openLinkInNewTab(_ url: URL) {
        ChatLink.open(url) { url in
            let newTabId = tabManager.newTab(url: url)
            webViewWrapper.load(url: url, in: newTabId)
        }
    }

    // MARK: - Context helpers

    private func buildContextString() -> String? {
        var parts: [String] = []

        for id in includedOtherTabIds {
            if let url = tabManager.tabURL[id] ?? nil {
                var tp: [String] = ["URL: \(url.absoluteString)"]
                let ctx = otherTabContexts[id]
                if let t = ctx?.title ?? tabManager.tabTitle[id], !t.isEmpty {
                    tp.append("Title: \(t)")
                }
                if let text = ctx?.text, !text.isEmpty {
                    tp.append("Page content:\n\(text)")
                }
                parts.append(tp.joined(separator: "\n"))
            }
        }

        for doc in attachedDocuments {
            parts.append("Document \"\(doc.displayName)\":\n\(doc.textForContext)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func otherTabLabel(tabId: UUID) -> String {
        if let title = tabManager.tabTitle[tabId], !title.isEmpty { return title }
        if let url = tabManager.tabURL[tabId] ?? nil, let host = url.host { return host }
        return "Tab"
    }

    private func removeIncludedOtherTab(id: UUID) {
        includedOtherTabIds.removeAll { $0 == id }
        otherTabContexts.removeValue(forKey: id)
    }

    private func loadTabContext(for id: UUID) {
        let group = DispatchGroup()
        var loadedTitle: String? = nil
        var loadedText: String? = nil

        group.enter()
        webViewWrapper.evaluatePageTitle(for: id) { title in
            loadedTitle = title; group.leave()
        }
        group.enter()
        webViewWrapper.evaluateVisibleText(for: id, maxChars: 4000) { text in
            loadedText = text; group.leave()
        }
        group.notify(queue: .main) {
            otherTabContexts[id] = (title: loadedTitle, text: loadedText)
        }
    }

    /// Extracts text on a background task: PDF parsing can take seconds and
    /// must not block the main thread. The background task owns the security
    /// scope so sandboxed file access stays valid for the duration of the read.
    private func addDocument(from url: URL, securityScoped: Bool = false) {
        guard SmartDocumentExtractor.isSupported(url) else {
            documentError = "Unsupported format. Use PDF, TXT, MD, JSON, CSV, XML, or HTML."
            return
        }
        Task {
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                if securityScoped {
                    guard url.startAccessingSecurityScopedResource() else { return nil }
                }
                defer {
                    if securityScoped { url.stopAccessingSecurityScopedResource() }
                }
                return SmartDocumentExtractor.extractText(from: url)
            }.value
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                documentError = "Could not read text from \"\(url.lastPathComponent)\"."
                return
            }
            attachedDocuments.append(SmartAttachedDocument(
                displayName: url.lastPathComponent,
                extractedText: text,
                fileURL: url
            ))
            documentError = nil

            // Auto-enter AI chat when a file is added from the start page
            if viewState == .idle {
                enterChatWithContext()
            }
        }
    }

    private func enterChatWithContext() {
        if let id = tabId {
            let aiURL = URL(string: "luma://ai/\(id.uuidString)")!
            tabManager.navigate(tab: id, to: aiURL)
            tabManager.updateTitle(tab: id, title: "New Chat")
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            viewState = .aiChat
        }
        isInputFocused = true
    }

    private func removeAttachedDocument(id: UUID) {
        attachedDocuments.removeAll { $0.id == id }
    }

}

// MARK: - Thinking step model

private struct SmartThinkingStep: Identifiable {
    let id = UUID()
    let text: String
    var isComplete: Bool = false
}

// MARK: - Context chip


// MARK: - Growing input (self-contained, same pattern as CommandSurface)

private struct SmartGrowingInput: View {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    @FocusState.Binding var isFocused: Bool
    var onSubmit: () -> Void
    var onLargePaste: ((String) -> Void)?

    @State private var textHeight: CGFloat = 36

    private var font: Font { .system(size: fontSize) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SmartMultilineField(
                text: $text,
                fontSize: fontSize,
                dynamicHeight: $textHeight,
                minHeight: 36,
                onSubmit: onSubmit,
                onLargePaste: onLargePaste
            )
            .focused($isFocused)

            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundColor(Color.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: textHeight)
        .animation(.easeOut(duration: 0.15), value: textHeight)
    }
}

private struct SmartMultilineField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    @Binding var dynamicHeight: CGFloat
    var minHeight: CGFloat
    var onSubmit: () -> Void
    var onLargePaste: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tv = SmartSubmitTextView()
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.onLargePaste = onLargePaste
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = NSColor(white: 0.95, alpha: 1)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 5
        tv.defaultParagraphStyle = ps
        tv.typingAttributes[.paragraphStyle] = ps
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = tv
        context.coordinator.textView = tv

        DispatchQueue.main.async { context.coordinator.recalculateHeight(tv) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? SmartSubmitTextView else { return }
        let textChanged = tv.string != text
        if textChanged { tv.string = text }
        tv.onSubmit = onSubmit
        tv.onLargePaste = onLargePaste
        tv.font = .systemFont(ofSize: fontSize)
        if let container = tv.textContainer {
            let w = scrollView.contentSize.width
            if w > 0 { container.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude) }
        }
        if textChanged {
            DispatchQueue.main.async { context.coordinator.recalculateHeight(tv) }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SmartMultilineField
        weak var textView: SmartSubmitTextView?
        init(_ parent: SmartMultilineField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            recalculateHeight(tv)
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let container = textView.textContainer,
                  let manager = textView.layoutManager else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            let inset = textView.textContainerInset
            let h = max(parent.minHeight, used.height + inset.height * 2)
            if abs(h - parent.dynamicHeight) > 0.5 { parent.dynamicHeight = h }
        }
    }
}

private class SmartSubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onLargePaste: ((String) -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isNumpad = event.keyCode == 76
        if (isReturn || isNumpad) && !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if let clipboard = NSPasteboard.general.string(forType: .string),
           clipboard.count > 300 {
            onLargePaste?(clipboard)
            return
        }
        super.paste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return super.performKeyEquivalent(with: event) }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Add Tab Context Sheet


// MARK: - AttachedDocument

private struct SmartAttachedDocument: Identifiable {
    let id: UUID
    let displayName: String
    let extractedText: String
    let fileURL: URL?

    init(id: UUID = UUID(), displayName: String, extractedText: String, fileURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.extractedText = extractedText
        self.fileURL = fileURL
    }

    static let maxCharsInContext: Int = 12_000

    var textForContext: String {
        if extractedText.count <= Self.maxCharsInContext { return extractedText }
        return String(extractedText.prefix(Self.maxCharsInContext)) + "\n\n[Document truncated for length.]"
    }
}

// MARK: - DocumentTextExtractor

private enum SmartDocumentExtractor {
    nonisolated static let supportedExtensions: Set<String> = ["pdf", "txt", "md", "json", "csv", "xml", "html"]

    nonisolated static func extractText(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf": return PDFDocument(url: url)?.string
        case "txt", "md", "json", "csv", "xml", "html":
            return (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .utf16))
        default: return nil
        }
    }

    nonisolated static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
