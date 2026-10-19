import AppKit
import SwiftUI

// MARK: - GrowingTextEditor
//
// Height comes from the NSTextView's own layout manager — no invisible Text
// mirror, no PreferenceKey. The NSTextView reports its content height after
// every keystroke; the SwiftUI frame follows.

struct PanelTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat
    var fontSize: CGFloat = 13
    @FocusState.Binding var isFocused: Bool
    var onSubmit: (() -> Void)? = nil
    @Binding var reportedHeight: CGFloat
    /// Return sends (Shift-Return is a newline). When false only ⌘↩ sends.
    var submitOnReturn = true
    /// Esc while editing (stop a run). Return true if handled.
    var onEscape: (() -> Bool)? = nil
    /// ↑ in an empty field (edit the last message).
    var onArrowUpWhenEmpty: (() -> Void)? = nil
    var accessibilityLabel = "Message"

    @State private var textHeight: CGFloat = 36

    private var font: Font { .system(size: fontSize) }
    private let placeholderColor = Color(nsColor: .placeholderTextColor)

    var body: some View {
        ZStack(alignment: .topLeading) {
            MultilineTextField(
                text: $text,
                fontSize: fontSize,
                dynamicHeight: $textHeight,
                minHeight: minHeight,
                onSubmit: onSubmit,
                keys: .init(submitOnReturn: submitOnReturn, onEscape: onEscape, onArrowUpWhenEmpty: onArrowUpWhenEmpty),
                accessibilityLabel: accessibilityLabel
            )
            .focused($isFocused)

            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundColor(placeholderColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: textHeight)
        .onChange(of: textHeight) { _, h in reportedHeight = h }
        .onAppear { reportedHeight = textHeight }
        .animation(.easeOut(duration: 0.15), value: textHeight)
    }
}

// MARK: - MultilineTextField (NSTextView wrapper)
//
// Reports its own content height via `dynamicHeight` using the layout manager.
// No internal scrolling — the view always shows all text.

private struct MultilineTextField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    @Binding var dynamicHeight: CGFloat
    var minHeight: CGFloat
    var onSubmit: (() -> Void)?
    var keys: BorderedTextView.Keys
    var accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tv = BorderedTextView()
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.keys = keys
        tv.setAccessibilityLabel(accessibilityLabel)
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .labelColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        tv.defaultParagraphStyle = paragraphStyle
        tv.typingAttributes[.paragraphStyle] = paragraphStyle
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = tv
        context.coordinator.textView = tv

        DispatchQueue.main.async {
            context.coordinator.recalculateHeight(tv)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? BorderedTextView else { return }
        if tv.string != text {
            tv.string = text
        }
        tv.onSubmit = onSubmit
        tv.keys = keys
        tv.setAccessibilityLabel(accessibilityLabel)
        tv.font = .systemFont(ofSize: fontSize)
        if let container = tv.textContainer {
            let w = scrollView.contentSize.width
            if w > 0 {
                container.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
            }
        }
        // Defer height recalculation so we don't write @Binding during a view update
        DispatchQueue.main.async {
            context.coordinator.recalculateHeight(tv)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTextField
        weak var textView: BorderedTextView?

        init(_ parent: MultilineTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculateHeight(textView)
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let container = textView.textContainer,
                  let manager = textView.layoutManager else { return }
            manager.ensureLayout(for: container)
            let usedRect = manager.usedRect(for: container)
            let inset = textView.textContainerInset
            let newHeight = usedRect.height + inset.height * 2
            let clamped = max(parent.minHeight, newHeight)
            if abs(clamped - parent.dynamicHeight) > 0.5 {
                parent.dynamicHeight = clamped
            }
        }
    }
}

final class BorderedTextView: NSTextView {
    struct Keys {
        var submitOnReturn = true
        var onEscape: (() -> Bool)?
        var onArrowUpWhenEmpty: (() -> Void)?
    }

    var onSubmit: (() -> Void)?
    var keys = Keys()

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isReturn, !hasMarkedText(), flags.contains(.command) || (keys.submitOnReturn && !flags.contains(.shift) && !flags.contains(.option)) {
            onSubmit?()
            return
        }
        if event.keyCode == 53, keys.onEscape?() == true { return }
        if event.keyCode == 126, string.isEmpty, let up = keys.onArrowUpWhenEmpty {
            up()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘↩ sends even when a menu or button claims Return.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            onSubmit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
