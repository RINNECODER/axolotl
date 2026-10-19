// Luma MVP - AI Side Panel (redesigned for clarity, calmness, accessibility)
import Foundation
import SwiftUI
import WebKit
import AppKit
import PDFKit
import UniformTypeIdentifiers
import Combine

/// Right-side AI command panel (Cmd+E toggle). Per-tab chat with history.
///
/// Redesign: clear hierarchy (header → context → conversation → input),
/// calm visuals, WCAG contrast, keyboard + screen reader support.
struct CommandSurfaceView: View {
    @Binding var isPresented: Bool
    @Binding var messages: [ChatMessage]
    let webViewWrapper: WebViewWrapper
    let commandRouter: CommandRouter
    let gemini: GeminiClient
    let ollama: OllamaClient
    let historyManager: HistoryManager
    let onActionProposed: (LLMResponse) -> Void
    
    var tabId: UUID? = nil
    /// Other panes of this tab's split view: always part of the context.
    var splitPeers: [UUID] = []

    @AppStorage("luma_ai_panel_font_size") private var aiPanelFontSizeRaw: Int = 13
    @AppStorage("luma_ai_provider") private var aiProviderRaw: String = AIProvider.gemini.rawValue
    @AppStorage("luma_ollama_base_url") private var ollamaBaseURL: String = "http://127.0.0.1:11434"
    @AppStorage("luma_ollama_model") private var ollamaModel: String = ""
    @AppStorage(DevPrefs.panelModeKey) private var panelModeRaw: String = AIPanelMode.general.rawValue
    @AppStorage(DevPrefs.terminalKey) private var devTerminal: Bool = false
    @Environment(\.colorScheme) private var outerColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var modeSwitchNS
    @State private var inputText: String = ""
    @State private var errorMessage: String? = nil
    @State private var isSending: Bool = false
    @State private var actionProposedMessage: String? = nil
    @State private var conversationSummary: String? = nil
    @State private var lastSummarizedMessageCount: Int = 0
    /// Active streaming task — cancel to stop generation.
    @State private var streamingTask: Task<Void, Never>? = nil
    /// Incremented whenever a stream starts or is cancelled; stale callbacks compare
    /// their captured generation against this and bail out.
    @State private var streamGeneration: Int = 0
    /// A `/grab` paused on a sign-in page; Resume runs it again.
    @State private var composerMode: ComposerMode = .chat
    @State private var modeMenuOpen = false
    @AppStorage("luna_grab_service") private var grabServiceID: String = KeyService.registry[0].id
    @FocusState private var isInputFocused: Bool

    @State private var pageTitle: String? = nil
    @State private var pageText: String? = nil
    @State private var isLoadingContext: Bool = false

    @State private var attachedDocuments: [AttachedDocument] = []
    @State private var documentPickerPresented: Bool = false
    @State private var documentError: String? = nil
    @State private var includeCurrentTab: Bool = true // Current tab is always included initially
    @State private var includedOtherTabIds: [UUID] = []
    @State private var otherTabContexts: [UUID: (title: String?, text: String?)] = [:]
    @State private var addContextPresented: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var currentTabChipId: UUID = UUID()

    /// Tracks the editor's current natural height so the outer container can match it without any fixed frame.
    @State private var editorContentHeight: CGFloat = 36

    private let minInputHeight: CGFloat = 36

    private var chatFontSize: CGFloat { CGFloat(aiPanelFontSizeRaw) }

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .gemini
    }

    var body: some View {
        // Both modes share one frame; switching crossfades and slides them (no layout jump) while
        // the mode switch glides between its two homes.
        ZStack {
            if isDevMode {
                // Dev mode copies T3 Code: its own header (with the mode switch), surface and light/dark tokens.
                DevPanelView(fontSize: chatFontSize, onOpenSettings: openConnectAgents, onOpenLink: openLinkInNewTab,
                             modeSwitch: AnyView(modeSwitch()), onClose: close)
                    // Dev mode follows the app's appearance, like T3 Code.
                    .environment(\.colorScheme, outerColorScheme)
                    .transition(modeTransition(edge: .trailing))
            } else {
                VStack(spacing: 0) {
                    panelHeader()
                    if DevMode.isDevBuild {
                        modeSwitch().padding(.bottom, 6)
                    }
                    conversationStream()
                    MCPApprovalStack()
                    inputArea()
                }
                // Draws the composer's mode dropdown above the composer (not inside a scroll view).
                .devDropdownHost()
                // No surface of its own: the panel sits on the window chrome, like the
                // sidebar, so the browser, the page and the panel read as one piece.
                .environment(\.colorScheme, .dark)
                .transition(modeTransition(edge: .leading))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isDevMode)
        .overlay { if isDropTargeted { FileDropHint() } }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDocumentDrop(providers: providers)
        }
        // Load page context only when the sidebar is toggled open (not on every URL change).
        // Auto-reloading on navigation can look like automated scraping to strict sites (e.g. Akamai).
        .onAppear {
            MCPApprovalCenter.shared.panelAppeared()
            #if DEBUG
            if ProcessInfo.processInfo.environment["LUNA_SNAPSHOT_NEW_CHAT"] != nil { messages = [] }
            if let mode = ProcessInfo.processInfo.environment["LUNA_SNAPSHOT_COMPOSER"].flatMap(ComposerMode.init(rawValue:)) {
                composerMode = mode
            }
            if ProcessInfo.processInfo.environment["LUNA_SNAPSHOT_MODE_MENU"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { modeMenuOpen = true }
            }
            if let text = ProcessInfo.processInfo.environment["LUNA_SNAPSHOT_SEND"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { inputText = text; sendCommand() }
            }
            // Personalize screenshots: press Apply, then Undo, on the last card after these delays.
            for (key, action) in [("LUNA_SNAPSHOT_APPLY", CustomizationCardView.Action.apply), ("LUNA_SNAPSHOT_UNDO", .undo)] {
                if let delay = ProcessInfo.processInfo.environment[key].flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if let last = messages.last { handlePersonalize(action, messageId: last.id) }
                    }
                }
            }
            #endif
            restoreConversationSummary()
            loadPageContext()
            includeSplitPeers()
        }
        .onChange(of: splitPeers) { _, _ in includeSplitPeers() }
        // Parent can remove the panel (tab switch / close) without calling close();
        // cancel the stream so orphaned tasks don't keep mutating state.
        .onDisappear {
            MCPApprovalCenter.shared.panelDisappeared()
            if isSending { stopStreaming() }
            streamGeneration += 1
            streamingTask?.cancel()
            streamingTask = nil
            isSending = false
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
    }

    // MARK: - Header (minimal - note icon for new chat, model menu, close button)

    private func panelHeader() -> some View {
        HStack(spacing: 6) {
            PanelIconButton(systemName: "square.and.pencil", help: isDevMode ? "New Session" : "New Chat",
                            action: startNewChat)
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text("Luna")
                    .font(LunaType.brand(size: 15))
                if isDevMode {
                    Text("Dev · coding agents")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    PanelModelMenu(onOpenSettings: openModelSettings)
                }
            }
            Spacer(minLength: 0)
            PanelIconButton(systemName: "xmark", help: "Close (Esc)") {
                // Esc stops a running reply, agent run or Dev turn before it closes the panel.
                if isDevMode, DevWorkspace.shared.isTurnActive {
                    DevWorkspace.shared.interrupt()
                } else if !isDevMode, isSending {
                    stopStreaming()
                } else {
                    close()
                }
            }
            // The raw terminal needs Esc (it interrupts the CLI).
            .keyboardShortcut(isDevMode && devTerminal ? nil : KeyboardShortcut(.escape, modifiers: []))
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Dev mode only exists in the Luna Dev build, and only works unsandboxed.
    private var isDevMode: Bool {
        DevMode.isDevBuild && DevMode.isAvailable && panelModeRaw == AIPanelMode.dev.rawValue
    }

    /// General | Dev as small text tabs (T3 Code-style toggle group). Shown only in the Luna Dev build.
    /// The selection pill is a matched geometry, so it slides between tabs and between the two headers.
    private func modeSwitch() -> some View {
        HStack(spacing: 0) {
            ForEach([AIPanelMode.general, .dev], id: \.self) { mode in
                let selected = panelModeRaw == mode.rawValue
                Button {
                    guard !selected else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { panelModeRaw = mode.rawValue }
                } label: {
                    Text(mode == .general ? "General" : "Dev")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.09))
                                    .matchedGeometryEffect(id: "modeIndicator", in: modeSwitchNS)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .matchedGeometryEffect(id: "modeSwitch", in: modeSwitchNS)
        .disabled(!DevMode.isAvailable)
        .help(DevMode.isAvailable ? "Panel mode" : "Dev needs the unsandboxed Luna Dev build.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel mode")
    }

    private func modeTransition(edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(x: edge == .trailing ? 14 : -14)),
            removal: .opacity.combined(with: .offset(x: edge == .trailing ? 14 : -14)))
    }

    private func openConnectAgents() {
        SettingsOpener.open(.agents)
    }

    private func openModelSettings() {
        SettingsOpener.open(.ai)
    }

    private func startNewChat() {
        if isDevMode { DevWorkspace.shared.goHome(); return }
        streamingTask?.cancel()
        streamingTask = nil
        isSending = false
        messages = []
        attachedDocuments = []
        includeCurrentTab = true
        includedOtherTabIds = []
        otherTabContexts = [:]
        inputText = ""
        errorMessage = nil
        actionProposedMessage = nil
        conversationSummary = nil
        lastSummarizedMessageCount = 0
        composerMode = .chat
        editorContentHeight = minInputHeight
        loadPageContext() // Reload current page context
    }

    private func thisPageLabel() -> String {
        if let title = pageTitle, !title.isEmpty { return title }
        if let host = webViewWrapper.currentURL?.host { return host }
        return "Loading…"
    }

    // MARK: - Conversation stream

    private func conversationStream() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if messages.isEmpty {
                        emptyConversationState()
                    } else {
                        ForEach(messages) { msg in
                            PanelMessageRow(
                                message: msg,
                                fontSize: chatFontSize,
                                onLinkTapped: { url in openLinkInNewTab(url) },
                                onStopRun: stopStreaming,
                                onResumeGrab: resumeGrab,
                                onDismissGrab: { dismissGrab(id: msg.id) },
                                onPersonalize: { action in handlePersonalize(action, messageId: msg.id) },
                                isLastMessage: msg.id == messages.last?.id
                            )
                            .id(msg.id)
                            .frame(maxWidth: ChatTokens.chatMaxWidth, alignment: msg.role == .user ? .trailing : .leading)
                        }
                        if isSending, messages.last?.card == nil {
                            loadingIndicator()
                        }
                    }
                    if let err = errorMessage {
                        errorInlineView(message: err)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: messages.last?.card) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
    }

    /// Mirrors the start page: the moon, a quiet title, and capsule suggestions.
    private func emptyConversationState() -> some View {
        ChatEmptyState(
            title: "Ask about this page",
            subtitle: "Summarize, explain, or find anything — or let Luna do a task on this tab.",
            suggestions: [
                .init(title: "Summarize this page") { send("Summarize this page") },
                .init(title: "What are the key takeaways?") { send("What are the key takeaways?") },
                .init(title: "Do a task on this tab…") { setMode(.agent) },
                .init(title: "Get an API key…") { setMode(.grab) },
                .init(title: "Set up Luna the way I use it") { setMode(.personalize); sendCommand() },
            ],
            isBusy: isSending
        )
    }

    private func send(_ text: String) {
        composerMode = .chat
        inputText = text
        sendCommand()
    }

    private func setMode(_ mode: ComposerMode) {
        composerMode = mode
        isInputFocused = true
    }

    private func loadingIndicator() -> some View {
        LunaSayingRow(fontSize: chatFontSize)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Assistant is thinking")
    }

    private func errorInlineView(message: String) -> some View {
        ChatErrorBanner(message: message, fontSize: chatFontSize)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Input area
    //
    // Glass rounded-rect box (start page style). Grows to show all typed text.
    // No internal scrolling — you always see everything before sending.
    // The mode button on the left switches between Chat, Agent and Grab key.

    enum ComposerMode: String, CaseIterable {
        case chat, agent, grab, personalize

        var title: String {
            switch self {
            case .chat: return "Chat"
            case .agent: return "Agent"
            case .grab: return "Grab Key"
            case .personalize: return "Personalize"
            }
        }

        var systemImage: String {
            switch self {
            case .chat: return "bubble.left"
            case .agent: return "cursorarrow.rays"
            case .grab: return "key"
            case .personalize: return "slider.horizontal.3"
            }
        }

        var detail: String {
            switch self {
            case .chat: return "Ask about this page"
            case .agent: return "Do a task on this tab  /agent"
            case .grab: return "Create an API key into the Keychain  /grab"
            case .personalize: return "Set up Luna from how you use it  /personalize"
            }
        }

        /// One-line description for the mode dropdown (no slash command).
        var subtitle: String {
            switch self {
            case .chat: return "Ask about this page"
            case .agent: return "Do a task on this tab"
            case .grab: return "Create an API key into the Keychain"
            case .personalize: return "Set up Luna from how you use it"
            }
        }

        var slashCommand: String? {
            switch self {
            case .chat: return nil
            case .agent: return "/agent"
            case .grab: return "/grab"
            case .personalize: return "/personalize"
            }
        }

        var placeholder: String {
            switch self {
            case .chat: return "Ask anything…"
            case .agent: return "Describe a task for this tab…"
            case .grab: return "Key name (optional)"
            case .personalize: return "What should change? (optional)"
            }
        }
    }

    private var grabService: KeyService {
        KeyService.registry.first { $0.id == grabServiceID } ?? KeyService.registry[0]
    }

    private func inputArea() -> some View {
        VStack(spacing: 6) {
            if let documentError {
                Text(documentError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            switch composerMode {
            case .chat:
                if includeCurrentTab || !includedOtherTabIds.isEmpty || !attachedDocuments.isEmpty {
                    contextChips()
                }
            case .agent:
                modeHint("Runs on this tab · \(agentModelLabel)")
            case .grab:
                grabServiceRow()
            case .personalize:
                modeHint("Suggests settings and bookmarks · you approve each change")
            }

            HStack(alignment: .bottom, spacing: 2) {
                modeMenu()
                    .padding(.bottom, 3)
                if composerMode == .chat {
                    ChatAddContextButton(isActive: addContextPresented) { addContextPresented.toggle() }
                    .lunaPopover(isPresented: $addContextPresented, arrowEdge: .top) {
                        AddContextPopover(
                            tabs: otherTabItems,
                            included: Set(includedOtherTabIds),
                            onToggleTab: toggleIncludedTab,
                            onChooseFiles: {
                                addContextPresented = false
                                documentPickerPresented = true
                            }
                        )
                    }
                    .padding(.bottom, 3)
                }

                PanelTextEditor(
                    text: $inputText,
                    placeholder: composerMode == .grab ? "Key name (default \(KeyGrabber.defaultKeyName()))"
                                                       : composerMode.placeholder,
                    minHeight: minInputHeight,
                    fontSize: chatFontSize,
                    isFocused: $isInputFocused,
                    onSubmit: sendCommand,
                    reportedHeight: $editorContentHeight,
                    onArrowUpWhenEmpty: editLastMessage,
                    accessibilityLabel: composerMode.placeholder
                )
                .frame(maxWidth: .infinity)

                ChatSendStopButton(
                    isSending: isSending,
                    canSend: composerMode == .grab || composerMode == .personalize
                        || !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    onSend: sendCommand,
                    onStop: stopStreaming
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .lunaGlass(cornerRadius: 22, interactive: true)
            .focusShadow(isInputFocused)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Message input")
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(.top, 4)
    }

    private func contextChips() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if includeCurrentTab {
                    ContextChip(kind: .page(url: webViewWrapper.currentURL, faviconURL: tabId.flatMap { webViewWrapper.faviconURLByTab[$0] ?? nil }),
                                title: thisPageLabel(),
                                onRemove: { includeCurrentTab = false })
                }
                ForEach(includedOtherTabIds, id: \.self) { otherId in
                    ContextChip(kind: .tab(url: webViewWrapper.tabManager?.tabURL[otherId] ?? nil,
                                           faviconURL: webViewWrapper.faviconURLByTab[otherId] ?? nil),
                                title: otherTabLabel(tabId: otherId),
                                onRemove: { removeIncludedOtherTab(id: otherId) })
                }
                ForEach(attachedDocuments) { doc in
                    ContextChip(kind: .document(filename: doc.displayName),
                                title: doc.displayName,
                                onRemove: { removeAttachedDocument(id: doc.id) })
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 28)
    }

    /// One quiet line above the composer for the Agent mode.
    private func modeHint(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: composerMode.systemImage).font(.system(size: 10.5))
            Text(text).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundColor(ChatTokens.textTertiary)
        .padding(.horizontal, 18)
        .frame(height: 22)
    }

    /// Chat / Agent / Grab key. Same circle as the "+" button; the icon shows the mode.
    private func modeMenu() -> some View {
        DevDropdown(
            isOpen: $modeMenuOpen,
            items: ComposerMode.allCases.map { mode in
                DevDropdownItem(id: mode.rawValue, title: mode.title, subtitle: mode.subtitle,
                                detail: mode.slashCommand, icon: mode.systemImage,
                                iconColor: mode == composerMode ? ChatTokens.accent : nil)
            },
            selectedID: composerMode.rawValue,
            palette: .general,
            edge: .above,
            width: 300,
            presentation: .inWindow,
            onSelect: { item in
                if let mode = ComposerMode(rawValue: item.id) { setMode(mode) }
            }
        ) {
            Image(systemName: composerMode.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(composerMode == .chat ? ChatTokens.textSecondary : ChatTokens.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(composerMode == .chat ? 0 : 0.12)))
                .contentShape(Circle())
        }
        .disabled(isSending)
        .help("Mode: \(composerMode.title) — chat, run an agent task, or grab an API key")
        .accessibilityLabel("Mode: \(composerMode.title)")
    }

    private func grabServiceRow() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "key").font(.system(size: 10.5))
                .foregroundColor(ChatTokens.textTertiary)
            Text("Get an API key from")
                .font(.system(size: 11))
                .foregroundColor(ChatTokens.textTertiary)
            LunaMenuButton(minWidth: 180, items: {
                LunaMenuEntry.options(KeyService.registry.map { ($0.id, $0.name) }, selection: grabServiceID) {
                    grabServiceID = $0
                }
            }) { _ in
                ChatMenuLabel(text: grabService.name)
            }
            .fixedSize()
            .help("Service")
            .accessibilityLabel("Service: \(grabService.name)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 26)
    }

    private var agentModelLabel: String {
        KeyGrabber.defaultPolicy() is JevPolicy ? JevClient.configuredModel : LLMService.shared.modelName
    }

    /// ↑ in an empty composer puts the last message you sent back in it.
    private func editLastMessage() {
        guard !isSending, let last = messages.last(where: { $0.role == .user && $0.card == nil }) else { return }
        inputText = last.text
    }

    /// Open tabs other than this one, for the "+" popover.
    private var otherTabItems: [AddContextPopover.TabItem] {
        guard let tm = webViewWrapper.tabManager else { return [] }
        return tm.tabOrder.filter { $0 != tabId }.compactMap { id in
            guard let url = tm.tabURL[id] ?? nil, url.scheme?.hasPrefix("http") == true else { return nil }
            return AddContextPopover.TabItem(id: id, title: otherTabLabel(tabId: id), url: url,
                                             faviconURL: webViewWrapper.faviconURLByTab[id] ?? nil)
        }
    }

    /// Split view: every pane's page is context, alongside this one.
    private func includeSplitPeers() {
        for id in splitPeers where !includedOtherTabIds.contains(id) {
            includedOtherTabIds.append(id)
            loadTabContext(for: id)
        }
    }

    private func toggleIncludedTab(_ id: UUID) {
        if includedOtherTabIds.contains(id) {
            removeIncludedOtherTab(id: id)
        } else {
            includedOtherTabIds.append(id)
            loadTabContext(for: id)
        }
    }

    private func openLinkInNewTab(_ url: URL) {
        // Only allow web schemes; model-generated markdown could contain
        // javascript:/file:/data: links which must never navigate the browser.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        if let tabManager = webViewWrapper.tabManager {
            let newTabId = tabManager.newTab(url: url)
            webViewWrapper.load(url: url, in: newTabId)
        }
    }

    /// Extracts text on a background task: PDF parsing can take seconds and
    /// must not block the main thread. The background task owns the security
    /// scope so sandboxed file access stays valid for the duration of the read.
    private func addDocument(from url: URL, securityScoped: Bool = false) {
        guard DocumentTextExtractor.isSupported(url) else {
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
                return DocumentTextExtractor.extractText(from: url)
            }.value
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                documentError = "Could not read text from “\(url.lastPathComponent)”."
                return
            }
            attachedDocuments.append(AttachedDocument(displayName: url.lastPathComponent, extractedText: text, fileURL: url))
            documentError = nil
        }
    }

    private func removeAttachedDocument(id: UUID) {
        attachedDocuments.removeAll { $0.id == id }
    }

    private func handleDocumentDrop(providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let u = url else { return }
                DispatchQueue.main.async { addDocument(from: u) }
            }
        }
        return true
    }

    private func close() {
        streamingTask?.cancel()
        streamingTask = nil
        isPresented = false
        inputText = ""
        errorMessage = nil
        isSending = false
        actionProposedMessage = nil
        attachedDocuments = []
        includeCurrentTab = true
        editorContentHeight = minInputHeight
    }

    /// Loads page context (title + visible text) when panel appears.
    private func loadPageContext() {
        isLoadingContext = true
        let group = DispatchGroup()

        group.enter()
        webViewWrapper.evaluatePageTitle { title in
            pageTitle = title
            group.leave()
        }

        group.enter()
        webViewWrapper.evaluateVisibleText(maxChars: 4000) { text in
            pageText = text
            group.leave()
        }

        group.notify(queue: .main) {
            isLoadingContext = false
        }
    }
    
    /// Loads page context (title + visible text) for a specific tab.
    private func loadTabContext(for tabId: UUID) {
        let group = DispatchGroup()
        var loadedTitle: String? = nil
        var loadedText: String? = nil

        group.enter()
        webViewWrapper.evaluatePageTitle(for: tabId) { title in
            loadedTitle = title
            group.leave()
        }

        group.enter()
        webViewWrapper.evaluateVisibleText(for: tabId, maxChars: 4000) { text in
            loadedText = text
            group.leave()
        }

        group.notify(queue: .main) {
            otherTabContexts[tabId] = (title: loadedTitle, text: loadedText)
        }
    }

    /// Builds context string from enabled context sources (current tab + attached files).
    private func buildContextString() -> String? {
        var parts: [String] = []

        // Include current tab context if enabled
        if includeCurrentTab {
            if let url = webViewWrapper.currentURL {
                parts.append("URL: \(url.absoluteString)")
            }
            if let title = pageTitle, !title.isEmpty {
                parts.append("Title: \(title)")
            }
            if let text = pageText, !text.isEmpty {
                parts.append("Page content:\n\(text)")
            }
        }

        // Include other tabs (same format as current tab: URL + title + page content)
        if let tm = webViewWrapper.tabManager {
            for id in includedOtherTabIds {
                if let url = tm.tabURL[id] ?? nil {
                    var tabParts: [String] = []
                    tabParts.append("URL: \(url.absoluteString)")
                    let context = otherTabContexts[id]
                    if let title = context?.title, !title.isEmpty {
                        tabParts.append("Title: \(title)")
                    } else if let t = tm.tabTitle[id], !t.isEmpty {
                        tabParts.append("Title: \(t)")
                    }
                    if let text = context?.text, !text.isEmpty {
                        tabParts.append("Page content:\n\(text)")
                    }
                    parts.append(tabParts.joined(separator: "\n"))
                }
            }
        }

        // Include attached documents
        for doc in attachedDocuments {
            parts.append("Document \"\(doc.displayName)\":\n\(doc.textForContext)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func otherTabLabel(tabId: UUID) -> String {
        guard let tm = webViewWrapper.tabManager else { return "Tab" }
        if let title = tm.tabTitle[tabId], !title.isEmpty { return title }
        if let url = tm.tabURL[tabId] ?? nil, let host = url.host { return host }
        return "Tab"
    }

    private func removeIncludedOtherTab(id: UUID) {
        includedOtherTabIds.removeAll { $0 == id }
        otherTabContexts.removeValue(forKey: id)
    }

    private func sendCommand() {
        // A send while a stream is active would corrupt message indices; require Stop first.
        guard !isSending else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)

        if composerMode == .grab {
            runGrab(service: grabService, keyName: trimmed.isEmpty ? KeyGrabber.defaultKeyName() : trimmed)
            return
        }
        if composerMode == .personalize {
            runPersonalize(request: trimmed)
            return
        }
        if trimmed.lowercased() == "/personalize" { inputText = ""; setMode(.personalize); return }
        guard !trimmed.isEmpty else { return }

        // Slash commands stay as shortcuts for the composer modes.
        let lower = trimmed.lowercased()
        if lower == "/agent" { inputText = ""; setMode(.agent); return }
        if lower == "/grab" { inputText = ""; setMode(.grab); return }
        if composerMode == .agent {
            runAgent(goal: trimmed)
            return
        }
        if let goal = Self.agentGoal(in: trimmed) {
            runAgent(goal: goal)
            return
        }
        if let grab = Self.grabRequest(in: trimmed) {
            guard let service = KeyService.resolve(grab.service) else {
                errorMessage = "Usage: /grab <service> [key name]"
                return
            }
            runGrab(service: service, keyName: grab.keyName ?? KeyGrabber.defaultKeyName())
            return
        }

        if let tabManager = webViewWrapper.tabManager,
           let response = commandRouter.proposal(for: trimmed, tabManager: tabManager) {
            messages.append(ChatMessage(role: .user, text: trimmed))
            messages.append(ChatMessage(role: .assistant, text: response.text))
            inputText = ""
            onActionProposed(response)
            return
        }

        isSending = true
        errorMessage = nil
        actionProposedMessage = nil

        let userMsg = ChatMessage(
            role: .user,
            text: trimmed,
            pageURL: webViewWrapper.currentURL?.absoluteString,
            pageTitle: pageTitle
        )
        messages.append(userMsg)
        inputText = ""

        let context = buildContextString()
        proceedWithStreaming(prompt: trimmed, context: context)
    }

    /// `/agent <goal>` runs the computer-use agent on this tab.
    static func agentGoal(in input: String) -> String? {
        guard input.lowercased().hasPrefix("/agent ") else { return nil }
        let goal = input.dropFirst("/agent ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? nil : goal
    }

    /// `/grab <service> [key name]`. A multi-word service ("hugging face") wins over a key name.
    static func grabRequest(in input: String) -> (service: String, keyName: String?)? {
        guard input.lowercased().hasPrefix("/grab ") else { return nil }
        let words = input.dropFirst("/grab ".count).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        for i in stride(from: words.count, through: 1, by: -1) {
            let name = words[0..<i].joined(separator: " ")
            if KeyService.resolve(name)?.known == true {
                return (name, i < words.count ? words[i...].joined(separator: " ") : nil)
            }
        }
        return (words[0], words.count > 1 ? words[1...].joined(separator: " ") : nil)
    }

    private var agentWebView: WKWebView? {
        tabId.flatMap(webViewWrapper.webViewIfLoaded) ?? webViewWrapper.activeWebView
    }

    /// Applies `change` to the card of message `id` and keeps its plain-text summary in step.
    private func updateCard(_ id: UUID, _ change: (inout ChatCard) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }), var card = messages[idx].card else { return }
        change(&card)
        messages[idx].card = card
        switch card {
        case .agentRun(let run): messages[idx].text = run.transcript
        case .grab(let grab): messages[idx].text = grab.transcript
        case .personalize(let p): messages[idx].text = p.transcript
        }
    }

    /// Runs the key grabber on this tab. The key goes to the Keychain and clipboard only;
    /// the card shows the agent's steps and where the key was saved, never the value.
    private func runGrab(service: KeyService, keyName: String) {
        guard let webView = agentWebView else {
            errorMessage = "Open a page in this tab first."
            return
        }
        isSending = true
        errorMessage = nil
        inputText = ""
        Usage.record(.aiGrabKey)
        let card = GrabCard(service: service, keyName: keyName, model: agentModelLabel)
        let reply = ChatMessage(role: .assistant, text: card.transcript, card: .grab(card))
        messages.append(reply)
        let replyId = reply.id
        streamGeneration += 1
        let generation = streamGeneration
        streamingTask = Task {
            let result = await KeyGrabber.shared.grab(service: service, keyName: keyName, webView: webView,
                                                      navigate: { webView.load(URLRequest(url: $0)) },
                                                      onEvent: { event in
                guard generation == streamGeneration else { return }
                updateCard(replyId) { if case .grab(var g) = $0 { g.run.apply(event); $0 = .grab(g) } }
            })
            guard generation == streamGeneration else { return }
            updateCard(replyId) { if case .grab(var g) = $0 { g.finish(result); $0 = .grab(g) } }
            isSending = false
            streamingTask = nil
        }
    }

    private func resumeGrab(_ card: GrabCard) {
        guard !isSending else { return }
        let service = KeyService.registry.first { $0.id == card.serviceID } ?? KeyService.resolve(card.serviceName)
        guard let service else { return }
        runGrab(service: service, keyName: card.keyName)
    }

    private func dismissGrab(id: UUID) {
        updateCard(id) {
            if case .grab(var g) = $0 { g.status = .stopped; g.message = "Cancelled."; $0 = .grab(g) }
        }
    }

    // MARK: Personalize

    /// Reads the opt-in usage record, asks the chosen model for a proposal restricted to the
    /// settings registry, bookmarks and favorites, and shows it as a preview card. Nothing
    /// changes until the user presses Apply.
    private func runPersonalize(request: String) {
        isSending = true
        errorMessage = nil
        inputText = ""
        Usage.record(.aiPersonalize)
        if !request.isEmpty { messages.append(ChatMessage(role: .user, text: request)) }
        let card = CustomizationCard(request: request, source: LLMService.shared.modelName)
        let reply = ChatMessage(role: .assistant, text: card.transcript, card: .personalize(card))
        messages.append(reply)
        let replyId = reply.id
        streamGeneration += 1
        let generation = streamGeneration
        let ctx = LunaBrowserHosts.shared.current?.personalization
        var useModel = true
        #if DEBUG
        if ProcessInfo.processInfo.environment["LUNA_SNAPSHOT_PERSONALIZE_OFFLINE"] != nil { useModel = false }
        #endif
        let askModel = useModel
        streamingTask = Task {
            let proposal = await Personalize.propose(request: request, ctx: ctx, useModel: askModel)
            guard generation == streamGeneration else { return }
            updateCard(replyId) { $0 = .personalize(proposal) }
            isSending = false
            streamingTask = nil
        }
    }

    private func handlePersonalize(_ action: CustomizationCardView.Action, messageId: UUID) {
        guard let message = messages.first(where: { $0.id == messageId }), case .personalize(var card)? = message.card else { return }
        switch action {
        case .toggle(let itemId):
            if let i = card.items.firstIndex(where: { $0.id == itemId }) { card.items[i].include.toggle() }
        case .apply:
            do {
                let change = try Customizer.shared.apply(card.plan, context: LunaBrowserHosts.shared.current?.personalization,
                                                         source: "Luna")
                card.status = .applied
                card.changeId = change.id
                card.message = nil
            } catch {
                card.message = error.localizedDescription
            }
        case .cancel:
            card.status = .cancelled
        case .undo:
            guard let id = card.changeId else { return }
            do {
                _ = try Customizer.shared.undo(id)
                card.status = .undone
                card.message = nil
            } catch {
                card.message = error.localizedDescription
            }
        case .openSettings:
            SettingsOpener.open(.privacy)
            return
        }
        updateCard(messageId) { $0 = .personalize(card) }
    }

    /// Streams each agent step into a run card. Stop cancels the run.
    private func runAgent(goal: String) {
        guard let webView = agentWebView else {
            errorMessage = "Open a page in this tab first."
            return
        }
        isSending = true
        errorMessage = nil
        inputText = ""
        Usage.record(.aiAgent)
        let agent = LunaToolbox.agent(for: webView)
        let model = agent.policy is JevPolicy ? JevClient.configuredModel : LLMService.shared.modelName
        let card = AgentRunCard(goal: goal, model: model)
        let reply = ChatMessage(role: .assistant, text: card.transcript,
                                pageURL: webViewWrapper.currentURL?.absoluteString, pageTitle: pageTitle,
                                card: .agentRun(card))
        messages.append(reply)
        let replyId = reply.id
        streamGeneration += 1
        let generation = streamGeneration
        streamingTask = Task {
            for await event in agent.run(goal: goal) {
                guard generation == streamGeneration else { continue }
                updateCard(replyId) { if case .agentRun(var r) = $0 { r.apply(event); $0 = .agentRun(r) } }
            }
            guard generation == streamGeneration else { return }
            isSending = false
            streamingTask = nil
        }
    }

    private func stopStreaming() {
        // Invalidate the current stream generation so late onToken/onCompletion
        // callbacks from the cancelled task are ignored.
        streamGeneration += 1
        streamingTask?.cancel()
        streamingTask = nil
        isSending = false
        guard let last = messages.last, last.role == .assistant else { return }
        if last.card != nil {
            updateCard(last.id) { card in
                switch card {
                case .agentRun(var r): r.markStopped(); card = .agentRun(r)
                case .grab(var g):
                    if g.status == .running { g.run.markStopped(); g.status = .stopped }
                    card = .grab(g)
                case .personalize(var p):
                    if p.status == .thinking { p.status = .cancelled; p.message = "Stopped." }
                    card = .personalize(p)
                }
            }
        } else if !last.text.isEmpty {
            messages[messages.count - 1].text += "\n\n*[Generation stopped]*"
        } else {
            messages.removeLast()
        }
    }

    private func proceedWithStreaming(prompt: String, context: String?) {
        Usage.record(.aiChat)
        let recentContext = Array(messages.dropLast().suffix(6))

        // Append placeholder for assistant response
        let placeholder = ChatMessage(
            role: .assistant,
            text: "",
            pageURL: webViewWrapper.currentURL?.absoluteString,
            pageTitle: pageTitle
        )
        messages.append(placeholder)
        // Track by stable message id (indices go stale when messages are
        // removed/edited) and by generation (stale callbacks after Stop must not run).
        let placeholderId = placeholder.id
        streamGeneration += 1
        let generation = streamGeneration

        let onToken: (String) -> Void = { token in
            guard generation == streamGeneration,
                  let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
            messages[idx].text += token
        }

        let onCompletion: (Result<Void, Error>) -> Void = { result in
            guard generation == streamGeneration else { return }
            isSending = false
            streamingTask = nil
            switch result {
            case .success:
                checkAndSummarize()
            case .failure(let error):
                let msg = error.localizedDescription
                errorMessage = msg
                if let idx = messages.firstIndex(where: { $0.id == placeholderId }) {
                    if messages[idx].text.isEmpty {
                        messages[idx].text = "Error: \(msg)"
                    } else {
                        messages[idx].text += "\n\n*[Error: \(msg)]*"
                    }
                }
            }
        }

        streamingTask = LLMService.shared.stream(
            LLMRequest(prompt: prompt, context: context, recentMessages: recentContext, conversationSummary: conversationSummary),
            onToken: onToken,
            onCompletion: onCompletion
        )
    }
    
    private func checkAndSummarize() {
        // Auto-summarize every 8 messages (4 exchanges)
        let messagesToSummarize = messages.count - lastSummarizedMessageCount
        
        if messagesToSummarize >= 8 {
            let messagesToProcess = Array(messages.suffix(messagesToSummarize))
            // Capture the summarized span now: messages can grow while the
            // summarize request is in flight, which would corrupt the range.
            let summarizedUpTo = messages.count

            let completion: (Result<String, Error>) -> Void = { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let summary):
                        // Append to existing summary or create new one
                        if let existing = conversationSummary {
                            conversationSummary = "\(existing)\n\nRecent: \(summary)"
                        } else {
                            conversationSummary = summary
                        }
                        lastSummarizedMessageCount = summarizedUpTo

                        // Save summary to history if we have a tab ID
                        if let tabId = tabId {
                            let summaryObj = ConversationSummary(
                                tabId: tabId,
                                summary: summary,
                                messageRange: (summarizedUpTo - messagesToSummarize)...(summarizedUpTo - 1)
                            )
                            historyManager.addConversationSummary(tabId: tabId, summary: summaryObj)
                        }
                        
                    case .failure:
                        // Silently fail - summarization is optimization, not critical
                        break
                    }
                }
            }
            LLMService.shared.summarize(messagesToProcess, completion: completion)
        }
    }

    private func restoreConversationSummary() {
        guard let tabId else { return }
        let summaries = historyManager.getSummariesForTab(tabId: tabId)
        conversationSummary = summaries.last?.summary
        lastSummarizedMessageCount = summaries.last.map { $0.messageRange.upperBound + 1 } ?? 0
    }
}

// MARK: - Attached documents (upload for AI context)

private struct AttachedDocument: Identifiable {
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

    /// Max chars per document in context to avoid token overflow.
    static let maxCharsInContext: Int = 12_000

    var textForContext: String {
        if extractedText.count <= Self.maxCharsInContext { return extractedText }
        return String(extractedText.prefix(Self.maxCharsInContext)) + "\n\n[Document truncated for length.]"
    }
}


// MARK: - Document text extraction

private enum DocumentTextExtractor {
    nonisolated static let supportedExtensions: Set<String> = ["pdf", "txt", "md", "json", "csv", "xml", "html"]

    nonisolated static func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return nil }
            return doc.string
        case "txt", "md", "json", "csv", "xml", "html":
            return (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .utf16))
        default:
            return nil
        }
    }

    nonisolated static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
