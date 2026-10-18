import SwiftUI

// A T3 Code-style dropdown (https://github.com/pingdotgg/t3code, MIT License): a flat popover card
// with an optional search field, grouped sections, a checkmark on the selection, secondary text,
// hover and keyboard navigation (↑ ↓ ↩ Esc). Used for every Dev picker instead of `Picker`/`Menu`.
//
// In the Dev panel it is drawn inside the window (`devDropdownHost()` on the panel root), so it has
// no system chrome; elsewhere (`.popover` presentation, e.g. Settings) it sits in a popover.

// MARK: - Model (pure, tested)

struct DevDropdownItem: Identifiable, Equatable {
    enum Role: Equatable { case option, action }

    let id: String
    var title: String
    /// Second line (description, path, hint).
    var subtitle: String?
    /// Trailing secondary text (effort, version).
    var detail: String?
    /// Small capsule after the title ("Default").
    var badge: String?
    var icon: String?
    var iconColor: Color?
    var section: String?
    var isEnabled = true
    /// Shown instead of `detail` when disabled ("Not supported yet").
    var disabledReason: String?
    /// Extra words the search matches.
    var keywords: [String] = []
    var role: Role = .option
}

struct DevDropdownModel: Equatable {
    /// More options than this shows the search field.
    static let searchThreshold = 6

    let items: [DevDropdownItem]
    let selectedID: String?
    private(set) var highlightedID: String?
    var query: String = "" {
        didSet { if query != oldValue { resetHighlight(preferSelection: query.isEmpty) } }
    }

    init(items: [DevDropdownItem], selectedID: String?) {
        self.items = items
        self.selectedID = selectedID
        resetHighlight(preferSelection: true)
    }

    var showsSearch: Bool { items.filter { $0.role == .option }.count > Self.searchThreshold }

    /// Options matching the query (title, subtitle, detail, keywords; every word must match),
    /// then actions, which are never filtered out.
    var visible: [DevDropdownItem] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let options = items.filter { $0.role == .option }.filter { item in
            guard !words.isEmpty else { return true }
            let hay = ([item.title, item.subtitle ?? "", item.detail ?? "", item.section ?? ""] + item.keywords)
                .joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        return options + items.filter { $0.role == .action }
    }

    /// Visible items grouped by section, in first-appearance order. Actions form a trailing group.
    var sections: [(title: String?, items: [DevDropdownItem])] {
        var out: [(title: String?, items: [DevDropdownItem])] = []
        for item in visible {
            let key: String? = item.role == .action ? "\u{0}actions" : item.section
            if let i = out.firstIndex(where: { $0.title == key }) {
                out[i].items.append(item)
            } else {
                out.append((key, [item]))
            }
        }
        return out.map { ($0.title == "\u{0}actions" ? nil : $0.title, $0.items) }
    }

    var hasNoMatches: Bool { !query.isEmpty && !visible.contains { $0.role == .option } }

    private var navigable: [DevDropdownItem] { visible.filter(\.isEnabled) }

    /// Moves the highlight by `delta` over enabled visible items, wrapping around.
    mutating func move(_ delta: Int) {
        let list = navigable
        guard !list.isEmpty else { highlightedID = nil; return }
        guard let current = highlightedID, let i = list.firstIndex(where: { $0.id == current }) else {
            highlightedID = (delta >= 0 ? list.first : list.last)?.id
            return
        }
        highlightedID = list[((i + delta) % list.count + list.count) % list.count].id
    }

    mutating func highlight(_ id: String) {
        if navigable.contains(where: { $0.id == id }) { highlightedID = id }
    }

    /// The item ↩ picks: the highlighted one if enabled and visible.
    func commit() -> DevDropdownItem? {
        guard let id = highlightedID else { return nil }
        return navigable.first { $0.id == id }
    }

    private mutating func resetHighlight(preferSelection: Bool) {
        let list = navigable
        if preferSelection, let selectedID, list.contains(where: { $0.id == selectedID }) {
            highlightedID = selectedID
        } else {
            highlightedID = list.first(where: { $0.role == .option })?.id ?? list.first?.id
        }
    }
}

// MARK: - List view

/// The dropdown card itself.
struct DevDropdownList: View {
    @State private var model: DevDropdownModel
    private let items: [DevDropdownItem]
    private let selectedID: String?
    let palette: T3Palette
    let width: CGFloat
    let maxHeight: CGFloat
    var footnote: String?
    let onSelect: (DevDropdownItem) -> Void
    let onDismiss: () -> Void

    @FocusState private var focused: Bool

    init(items: [DevDropdownItem], selectedID: String?, palette: T3Palette, width: CGFloat, maxHeight: CGFloat = 340,
         footnote: String? = nil, onSelect: @escaping (DevDropdownItem) -> Void, onDismiss: @escaping () -> Void) {
        _model = State(initialValue: DevDropdownModel(items: items, selectedID: selectedID))
        self.items = items
        self.selectedID = selectedID
        self.palette = palette
        self.width = width
        self.maxHeight = maxHeight
        self.footnote = footnote
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    private var p: T3Palette { palette }
    static func popoverFill(_ p: T3Palette) -> Color { p.isDark ? Color(hex: 0x161616) : .white }

    var body: some View {
        VStack(spacing: 0) {
            if model.showsSearch {
                searchField
                Rectangle().fill(p.border).frame(height: 1)
            }
            ViewThatFits(in: .vertical) {
                rows
                ScrollViewReader { proxy in
                    ScrollView { rows }
                        .scrollIndicators(.automatic)
                        .onChange(of: model.highlightedID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                        .onAppear { if let id = model.highlightedID { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .frame(maxHeight: maxHeight - (model.showsSearch ? 38 : 0) - (footnote == nil ? 0 : 28))
            .fixedSize(horizontal: false, vertical: true)
            if let footnote {
                Rectangle().fill(p.border).frame(height: 1)
                Text(footnote)
                    .font(.system(size: T3Metrics.text2xs))
                    .foregroundStyle(p.mutedForeground)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
            }
        }
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Self.popoverFill(p)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(p.isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(p.isDark ? 0.5 : 0.14), radius: 18, y: 8)
        .focusable(!model.showsSearch)
        .focusEffectDisabled()
        .focused($focused)
        .modifier(DropdownKeys(model: $model, commit: commitHighlighted, dismiss: onDismiss))
        .task {
            // After the list is in the window, so focus moves off the composer.
            try? await Task.sleep(for: .milliseconds(30))
            focused = true
        }
        // Lists that load while open (harnesses, models) update in place, keeping the search.
        .onChange(of: items) { _, _ in rebuild() }
        .onChange(of: selectedID) { _, _ in rebuild() }
        .accessibilityElement(children: .contain)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(p.mutedForeground)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(p.foreground)
                .focused($focused)
                .onSubmit(commitHighlighted)
                .modifier(DropdownKeys(model: $model, commit: commitHighlighted, dismiss: onDismiss))
                .accessibilityLabel("Search")
        }
        .padding(.horizontal, 11)
        .frame(height: 37)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) {
            let sections = model.sections
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Rectangle().fill(p.border).frame(height: 1).padding(.vertical, 4).padding(.horizontal, -4)
                }
                if let title = section.title {
                    Text(title)
                        .font(.system(size: T3Metrics.text2xs, weight: .medium))
                        .foregroundStyle(p.mutedForeground)
                        .padding(.horizontal, 8)
                        .padding(.top, index == 0 ? 2 : 0)
                        .frame(height: 22, alignment: .center)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(section.items) { item in row(item) }
            }
            if model.hasNoMatches {
                Text("No matches")
                    .font(.system(size: T3Metrics.textXs))
                    .foregroundStyle(p.mutedForeground)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
            }
        }
        .padding(4)
    }

    private func row(_ item: DevDropdownItem) -> some View {
        let highlighted = model.highlightedID == item.id && item.isEnabled
        let selected = item.role == .option && item.id == model.selectedID
        return Button { if item.isEnabled { onSelect(item) } } label: {
            HStack(alignment: item.subtitle == nil ? .center : .firstTextBaseline, spacing: 8) {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(item.iconColor ?? p.mutedForeground)
                        .frame(width: 15)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: item.role == .action ? .regular : .medium))
                            .foregroundStyle(p.foreground)
                            .lineLimit(1)
                        if let badge = item.badge {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(p.mutedForeground)
                                .padding(.horizontal, 5)
                                .frame(height: 15)
                                .background(Capsule().fill(p.accent))
                                .overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
                        }
                    }
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: T3Metrics.text2xs))
                            .foregroundStyle(p.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 6)
                if let trailing = item.isEnabled ? item.detail : (item.disabledReason ?? item.detail) {
                    Text(trailing)
                        .font(.system(size: T3Metrics.text2xs))
                        .foregroundStyle(p.mutedForeground)
                        .lineLimit(1)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(p.primary)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                    .accessibilityHidden(!selected)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, item.subtitle == nil ? 0 : 5)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: T3Metrics.radiusSm, style: .continuous)
                .fill(highlighted ? p.accent.opacity(p.isDark ? 1.6 : 1) : .clear))
            .opacity(item.isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .onHover { if $0 { model.highlight(item.id) } }
        .id(item.id)
        .accessibilityLabel([item.title, item.subtitle, item.isEnabled ? item.detail : item.disabledReason]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func rebuild() {
        var next = DevDropdownModel(items: items, selectedID: selectedID)
        next.query = model.query
        model = next
    }

    private func commitHighlighted() {
        if let item = model.commit() { onSelect(item) }
    }
}

private struct DropdownKeys: ViewModifier {
    @Binding var model: DevDropdownModel
    let commit: () -> Void
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.downArrow) { model.move(1); return .handled }
            .onKeyPress(.upArrow) { model.move(-1); return .handled }
            .onKeyPress(.return) { commit(); return .handled }
            .onKeyPress(.escape) { dismiss(); return .handled }
            .onExitCommand(perform: dismiss)
    }
}

// MARK: - Trigger + presentation

enum DevDropdownEdge { case above, below }

/// A trigger that opens a `DevDropdownList`.
///
/// `.inWindow` draws the list in the nearest `devDropdownHost()` (no system chrome); `.popover`
/// uses a popover (for hosts like Settings forms, where preferences do not reach a host).
struct DevDropdown<Label: View>: View {
    enum Presentation { case inWindow, popover }

    @Binding var isOpen: Bool
    let items: [DevDropdownItem]
    let selectedID: String?
    let palette: T3Palette
    var edge: DevDropdownEdge = .above
    var width: CGFloat = 260
    var footnote: String?
    var presentation: Presentation = .inWindow
    var help: String?
    let onSelect: (DevDropdownItem) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { isOpen.toggle() } label: { label() }
            .buttonStyle(T3GhostButtonStyle(palette: palette))
            .background(RoundedRectangle(cornerRadius: T3Metrics.radiusMd).fill(isOpen ? palette.accent : .clear))
            .help(help ?? "")
            .modifier(Presented(owner: self))
    }

    fileprivate func list(maxHeight: CGFloat) -> DevDropdownList {
        DevDropdownList(items: items, selectedID: selectedID, palette: palette, width: width, maxHeight: maxHeight,
                        footnote: footnote,
                        onSelect: { item in isOpen = false; onSelect(item) },
                        onDismiss: { isOpen = false })
    }

    private struct Presented: ViewModifier {
        let owner: DevDropdown

        func body(content: Content) -> some View {
            switch owner.presentation {
            case .popover:
                content.popover(isPresented: owner.$isOpen, arrowEdge: owner.edge == .above ? .top : .bottom) {
                    owner.list(maxHeight: 360).padding(6)
                }
            case .inWindow:
                content.anchorPreference(key: DevDropdownHostKey.self, value: .bounds) { anchor in
                    guard owner.isOpen else { return [] }
                    return [DevDropdownHostKey.Entry(anchor: anchor, edge: owner.edge, width: owner.width,
                                                     dismiss: { owner.isOpen = false },
                                                     content: { owner.list(maxHeight: $0) })]
                }
            }
        }
    }
}

struct DevDropdownHostKey: PreferenceKey {
    struct Entry {
        let anchor: Anchor<CGRect>
        let edge: DevDropdownEdge
        let width: CGFloat
        let dismiss: () -> Void
        let content: (CGFloat) -> DevDropdownList
    }

    static let defaultValue: [Entry] = []
    static func reduce(value: inout [Entry], nextValue: () -> [Entry]) { value += nextValue() }
}

extension View {
    /// Draws open `DevDropdown`s (in-window presentation) above this view. Clicking outside closes them.
    func devDropdownHost() -> some View {
        overlayPreferenceValue(DevDropdownHostKey.self) { entries in
            GeometryReader { proxy in
                if let entry = entries.last {
                    let rect = proxy[entry.anchor]
                    let size = proxy.size
                    let width = min(entry.width, size.width - 16)
                    let x = min(max(8, rect.minX), size.width - width - 8)
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.0001)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: entry.dismiss)
                            .accessibilityHidden(true)
                        switch entry.edge {
                        case .above:
                            let available = max(120, rect.minY - 12)
                            entry.content(min(380, available))
                                .frame(width: width)
                                .frame(width: size.width, height: rect.minY - 6, alignment: .bottomLeading)
                                .offset(x: x)
                                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                        case .below:
                            let available = max(120, size.height - rect.maxY - 12)
                            entry.content(min(380, available))
                                .frame(width: width)
                                .frame(width: size.width, height: size.height - rect.maxY - 6, alignment: .topLeading)
                                .offset(x: x, y: rect.maxY + 6)
                                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        }
                    }
                }
            }
        }
    }
}

/// The compact label T3 uses for composer pickers: icon, text, chevron.
struct DevPickerLabel: View {
    var icon: String?
    var iconColor: Color?
    let text: String
    var dimmed = false
    var maxTextWidth: CGFloat = 150
    let palette: T3Palette

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(iconColor ?? (dimmed ? palette.mutedForeground : palette.foreground.opacity(0.8)))
            }
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(dimmed ? palette.mutedForeground : palette.foreground.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxTextWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(palette.mutedForeground)
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .contentShape(Rectangle())
    }
}
