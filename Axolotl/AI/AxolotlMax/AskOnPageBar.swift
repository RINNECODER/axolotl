import SwiftUI
import WebKit

/// Arc-style "Ask on Page": a floating card over the page. Hold ⌘F (or press
/// ⌘⇧F) to open; the answer uses only the page's visible text.
struct AskOnPageBar: View {
    let tabId: UUID
    let web: WebViewWrapper
    let onClose: () -> Void

    @State private var question = ""
    @State private var answer: String?
    @State private var asked: String?
    @State private var error: String?
    @State private var isAsking = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Ask about this page…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(ask)
                if isAsking {
                    ProgressView().controlSize(.small)
                }
                PanelIconButton(systemName: "xmark", help: "Close (Esc)", action: close)
                    .keyboardShortcut(.cancelAction)
            }

            if let asked, answer != nil || error != nil || isAsking {
                Divider()
                Text(asked)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                ScrollView {
                    Group {
                        if let answer {
                            RichMessageView(rawText: answer, fontSize: 13, linkColor: AxolotlSurface.accent, onLinkTapped: { _ in })
                        } else if let error {
                            Text(error).font(.system(size: 12.5)).foregroundStyle(.red)
                        } else {
                            Text("Reading the page…").font(.system(size: 12.5)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 400)
        .background(AxolotlMaterialFill(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .onAppear { focused = true }
        .onDisappear { task?.cancel() }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAsking else { return }
        task?.cancel()
        asked = q
        question = ""
        answer = nil
        error = nil
        isAsking = true
        task = Task {
            let (title, text) = await pageContent()
            guard !Task.isCancelled else { return }
            do {
                guard let text, !text.isEmpty else { throw LLMError.stream("This page has no readable text.") }
                answer = try await AxolotlMax.askOnPage(question: q, title: title, url: web.webViewIfLoaded(for: tabId)?.url, pageText: text)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            isAsking = false
        }
    }

    private func pageContent() async -> (String?, String?) {
        async let title: String? = withCheckedContinuation { cont in web.evaluatePageTitle(for: tabId) { cont.resume(returning: $0) } }
        async let text: String? = withCheckedContinuation { cont in web.evaluateVisibleText(for: tabId, maxChars: 16_000) { cont.resume(returning: $0) } }
        return await (title, text)
    }

    private func close() {
        task?.cancel()
        onClose()
    }
}
