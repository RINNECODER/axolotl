import SwiftUI

/// Reports the focused-capable address field's bounds so the shell can place
/// suggestions directly under it in every layout.
struct AddressFieldAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The URL/search field shared by every layout. Shows the domain (or full
/// URL) until focused, then the editable address.
struct AddressField: View {
    let url: URL?
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var loadingProgress: Double?
    var centered: Bool = false
    var height: CGFloat = 30
    /// Off-screen fields (a hidden sidebar) must not claim the suggestions popup.
    var reportsAnchor: Bool = true
    /// Chrome layout template: Chrome's pill omnibox with the site-info chip and a trailing accessory (the star).
    var chromeStyle: Bool = false
    var trailing: AnyView? = nil
    let onSubmit: () -> Void

    @Environment(\.colorScheme) private var scheme

    @AppStorage(ChromePrefs.minimalURL) private var minimalURL = true
    @AppStorage(ChromePrefs.addressBarProgress) private var showProgress = true

    private var isWebPage: Bool {
        guard let url else { return false }
        return url.scheme == "http" || url.scheme == "https" || url.isFileURL
    }

    private var displayText: String {
        guard let url, isWebPage else { return "" }
        if url.isFileURL { return url.lastPathComponent }
        guard minimalURL else { return url.absoluteString }
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        let isFocused = focused.wrappedValue
        let palette = ChromePalette.for(scheme)
        let fontSize: CGFloat = chromeStyle ? 14.5 : 13
        HStack(spacing: chromeStyle ? 8 : 6) {
            if chromeStyle {
                // Chrome's site-information chip.
                Group {
                    if isWebPage { ChromeSiteInfoIcon().stroke(palette.icon, lineWidth: 1.5).frame(width: 14, height: 12) }
                    else { Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.icon) }
                }
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(palette.toolbar.opacity(isWebPage ? 1 : 0)))
            } else {
                Image(systemName: isWebPage ? (url?.scheme == "https" ? "lock.fill" : "globe") : "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
            }
            ZStack(alignment: centered && !isFocused ? .center : .leading) {
                TextField(chromeStyle ? "Search Google or type a URL" : "Search or enter address", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize))
                    .focused(focused)
                    .onSubmit(onSubmit)
                    .opacity(isFocused || displayText.isEmpty ? 1 : 0)
                if !isFocused, !displayText.isEmpty {
                    Text(displayText)
                        .font(.system(size: fontSize))
                        .foregroundStyle(chromeStyle ? AnyShapeStyle(palette.title) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                        .allowsHitTesting(false)
                }
            }
            // Balance the leading icon so centered text sits in the true middle.
            if centered && !isFocused { Color.clear.frame(width: 14) }
            if let trailing { trailing }
        }
        .padding(.leading, chromeStyle ? 5 : 10)
        .padding(.trailing, chromeStyle ? 6 : 10)
        .frame(height: height)
        .background {
            if chromeStyle {
                Capsule().fill(isFocused ? palette.toolbar : palette.omnibox)
                    .overlay(Capsule().strokeBorder(palette.star.opacity(isFocused ? 1 : 0), lineWidth: 2))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(isFocused ? 1 : 0.7))
            }
        }
        .overlay(alignment: .bottom) {
            if showProgress, let progress = loadingProgress, !isFocused {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: geo.size.width * max(0.08, progress), height: 2)
                        .animation(.easeOut(duration: 0.2), value: progress)
                }
                .frame(height: 2)
                .padding(.horizontal, 8)
                .padding(.bottom, 1)
            }
        }
        .modifier(OptionalFocusShadow(enabled: !chromeStyle, isFocused: isFocused))
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
        .anchorPreference(key: AddressFieldAnchorKey.self, value: .bounds) { reportsAnchor ? $0 : nil }
        .background(NonDraggableWindowView())
    }
}

/// Luna's floating shadow; Chrome's omnibox sits flat in the toolbar.
private struct OptionalFocusShadow: ViewModifier {
    let enabled: Bool
    let isFocused: Bool

    func body(content: Content) -> some View {
        if enabled { content.focusShadow(isFocused) } else { content }
    }
}
