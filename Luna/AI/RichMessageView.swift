// Luma — RichMessageView: combined MarkdownUI + LaTeXSwiftUI renderer
// Used by both the AI start page (SmartSearchView) and the side AI panel (CommandSurface).
//
// Strategy: split the response into top-level blocks (paragraphs, code fences,
// headings, list groups, etc.). Blocks that contain any LaTeX delimiters ($...$
// or $$...$$) are rendered entirely by LaTeXSwiftUI; all other blocks go through
// MarkdownUI. This avoids fragmented inline splitting that causes visual glitches.
import SwiftUI
import MarkdownUI
import LaTeXSwiftUI

// MARK: - Public view

struct RichMessageView: View {
    let rawText: String
    let fontSize: CGFloat
    let linkColor: Color
    var onLinkTapped: ((URL) -> Void)?

    /// Frozen text while a re-render is pending; nil shows `rawText`.
    @State private var shown: String?
    @State private var flush: Task<Void, Never>?

    var body: some View {
        // Streaming changes `rawText` per token; re-parsing the whole reply each time is costly,
        // so re-render at most ~10x/s. The Equatable content skips body when its text is unchanged.
        RichMessageContent(rawText: shown ?? rawText, fontSize: fontSize, linkColor: linkColor, onLinkTapped: onLinkTapped)
            .equatable()
            .onChange(of: rawText) { oldValue, _ in
                guard flush == nil else { return }
                shown = oldValue
                flush = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    shown = nil
                    flush = nil
                }
            }
            .onDisappear { flush?.cancel(); flush = nil; shown = nil }
    }
}

struct RichMessageContent: View, Equatable {
    let rawText: String
    let fontSize: CGFloat
    let linkColor: Color
    var onLinkTapped: ((URL) -> Void)?

    static func == (a: Self, b: Self) -> Bool {
        a.rawText == b.rawText && a.fontSize == b.fontSize && a.linkColor == b.linkColor
    }

    var body: some View {
        let text = Self.neutralizeRemoteImages(rawText)
        let blocks = Self.parseBlocks(text)
        let anyMath = blocks.contains { $0.containsMath }

        if !anyMath {
            markdownView(text)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    if block.containsMath {
                        latexBlockView(block.text)
                    } else if !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        markdownView(block.text)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Renderers

    private func markdownView(_ text: String) -> some View {
        Markdown(text)
            .markdownTheme(lumaTheme)
            .markdownTextStyle { FontSize(fontSize) }
            .markdownImageProvider(LocalOnlyImageProvider())
            .markdownInlineImageProvider(LocalOnlyInlineImageProvider())
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                onLinkTapped?(url)
                return .handled
            })
    }

    private func latexBlockView(_ text: String) -> some View {
        LaTeX(text)
            .parsingMode(.onlyEquations)
            .imageRenderingMode(.template)
            .foregroundStyle(Color.primary)
            .blockMode(.blockViews)
            .errorMode(.original)
            .renderingStyle(.original)
            .renderingAnimation(.easeIn)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: fontSize))
    }

    // MARK: - Block parser

    struct ContentBlock {
        let text: String
        let containsMath: Bool
    }

    /// Splits the input into top-level blocks separated by blank lines or code
    /// fences, then tags each block as math or not. Consecutive non-math blocks
    /// are merged so MarkdownUI can render multi-paragraph markdown in one pass.
    static func parseBlocks(_ input: String) -> [ContentBlock] {
        let lines = input.components(separatedBy: "\n")
        var rawBlocks: [String] = []
        var current: [String] = []
        var inCodeFence = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeFence {
                    current.append(line)
                    rawBlocks.append(current.joined(separator: "\n"))
                    current = []
                    inCodeFence = false
                } else {
                    if !current.isEmpty {
                        rawBlocks.append(current.joined(separator: "\n"))
                        current = []
                    }
                    current.append(line)
                    inCodeFence = true
                }
                continue
            }

            if inCodeFence {
                current.append(line)
                continue
            }

            if trimmed.isEmpty {
                if !current.isEmpty {
                    rawBlocks.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            rawBlocks.append(current.joined(separator: "\n"))
        }

        // Tag each block and merge consecutive non-math blocks
        var result: [ContentBlock] = []
        var pendingMarkdown: [String] = []

        for block in rawBlocks {
            let hasMath = Self.blockContainsMath(block)
            if hasMath {
                if !pendingMarkdown.isEmpty {
                    result.append(ContentBlock(
                        text: pendingMarkdown.joined(separator: "\n\n"),
                        containsMath: false
                    ))
                    pendingMarkdown = []
                }
                result.append(ContentBlock(text: block, containsMath: true))
            } else {
                pendingMarkdown.append(block)
            }
        }
        if !pendingMarkdown.isEmpty {
            result.append(ContentBlock(
                text: pendingMarkdown.joined(separator: "\n\n"),
                containsMath: false
            ))
        }

        return result
    }

    /// Returns true if the block contains any LaTeX math delimiters.
    /// Supports: $...$  $$...$$  \(...\)  \[...\]  \begin{equation}
    /// Ignores delimiters inside code fences and inline code spans.
    private static func blockContainsMath(_ block: String) -> Bool {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") { return false }

        var text = block
        // Strip inline code to avoid false positives on `$var` or `\(expr\)`
        while let start = text.range(of: "`"), let end = text[start.upperBound...].range(of: "`") {
            text.replaceSubrange(start.lowerBound...end.lowerBound, with: " ")
        }

        // Single `$`: opener not followed by a digit/space, closer not preceded by a space
        // or followed by a digit (pandoc's rule), so "$5 to $10" stays currency.
        let dollarPattern = #"(?s)(?<!\\)\$\$.*?(?<!\\)\$\$|(?<!\\)\$(?![\s\d$]).+?(?<![\s\\])\$(?!\d)"#
        if let regex = try? NSRegularExpression(pattern: dollarPattern),
           regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return true
        }
        if text.contains("\\(") && text.contains("\\)") { return true }
        if text.contains("\\[") && text.contains("\\]") { return true }
        if text.contains("\\begin{equation") { return true }
        return false
    }

    // MARK: - Images

    /// Model output must not make the browser fetch remote URLs (tracking pixels, exfiltration via
    /// query strings). Inline `![alt](url)` becomes a plain link showing the alt text; anything left
    /// (reference-style images) is dropped by the image providers unless it's a small data: image.
    /// shortcut: also rewrites `![..](..)` inside code spans/fences; fine for chat display.
    static func neutralizeRemoteImages(_ text: String) -> String {
        guard text.contains("![") else { return text }
        let regex = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(\s*<?(?!data:)([^)\s>]+)>?[^)\n]*\)"#)
        var out = text
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(m.range, in: text), let altR = Range(m.range(at: 1), in: text),
                  let urlR = Range(m.range(at: 2), in: text) else { continue }
            let alt = text[altR].trimmingCharacters(in: .whitespaces)
            out.replaceSubrange(whole, with: "[Image: \(alt.isEmpty ? String(text[urlR]) : alt)](\(text[urlR]))")
        }
        return out
    }

    static let maxDataImageBytes = 256 * 1024

    /// Decodes a data: image no larger than `maxDataImageBytes`; nil for anything else.
    static func smallDataImage(_ url: URL?) -> NSImage? {
        guard let url, url.scheme?.lowercased() == "data",
              url.absoluteString.utf8.count <= maxDataImageBytes * 4 / 3 + 256,
              let data = try? Data(contentsOf: url), data.count <= maxDataImageBytes else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Luma dark theme for MarkdownUI

    private var lumaTheme: MarkdownUI.Theme {
        .init()
            .text { ForegroundColor(Color.primary) }
            .link { ForegroundColor(linkColor); UnderlineStyle(.single) }
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }
            .strikethrough { StrikethroughStyle(.single) }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize + 10)
                        FontWeight(.bold)
                        ForegroundColor(Color.primary)
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize + 6)
                        FontWeight(.bold)
                        ForegroundColor(Color.primary)
                    }
                    .markdownMargin(top: 14, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize + 3)
                        FontWeight(.semibold)
                        ForegroundColor(Color.primary)
                    }
                    .markdownMargin(top: 12, bottom: 4)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize + 1)
                        FontWeight(.semibold)
                        ForegroundColor(Color.primary.opacity(0.92))
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading5 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize)
                        FontWeight(.semibold)
                        ForegroundColor(Color.primary.opacity(0.85))
                    }
                    .markdownMargin(top: 8, bottom: 2)
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(fontSize)
                        FontWeight(.medium)
                        ForegroundColor(Color.primary.opacity(0.8))
                    }
                    .markdownMargin(top: 6, bottom: 2)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(fontSize - 1)
                            ForegroundColor(Color.primary.opacity(0.92))
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .markdownMargin(top: 4, bottom: 4)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(fontSize - 1)
                BackgroundColor(Color.primary.opacity(0.08))
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(Color.primary.opacity(0.7)) }
                        .padding(.leading, 10)
                }
                .markdownMargin(top: 4, bottom: 4)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .table { configuration in
                configuration.label
                    .markdownTextStyle { FontSize(fontSize - 1) }
                    .markdownMargin(top: 4, bottom: 4)
            }
            .thematicBreak {
                Divider()
                    .overlay(Color.primary.opacity(0.15))
                    .markdownMargin(top: 8, bottom: 8)
            }
            .image { configuration in
                configuration.label
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
    }
}

private struct LocalOnlyImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        if let image = RichMessageContent.smallDataImage(url) {
            Image(nsImage: image).resizable().scaledToFit()
        }
    }
}

private struct LocalOnlyInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        guard let image = RichMessageContent.smallDataImage(url) else { throw URLError(.unsupportedURL) }
        return Image(nsImage: image)
    }
}
