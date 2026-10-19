import AppKit
import SwiftUI

/// Settings building blocks in Chrome's chrome://settings style: a centered column of rounded cards,
/// each row a title and description on the left and its control on the right, rows split by hairlines.
/// Every pane is built from these instead of `Form` / `.formStyle(.grouped)`.
enum SettingsStyle {
    /// Page backdrop behind the cards (and the nav when Liquid Glass is off).
    static let page = Color(light: .lunaHex(0xF1F2F4), dark: .lunaHex(0x1B1B1D))
    /// Card fill: a step lighter than the page.
    static let card = Color(light: .white, dark: .lunaHex(0x28282B))
    /// 1px card border.
    static let border = Color(light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.08))
    /// Hairline between rows in a card.
    static let hairline = Color(light: .black.withAlphaComponent(0.07), dark: .white.withAlphaComponent(0.07))
    /// The search field's fill.
    static let field = Color(light: .lunaHex(0xE4E6EA), dark: .lunaHex(0x2C2C30))
    /// Outlined button border.
    static let buttonBorder = Color(light: .black.withAlphaComponent(0.16), dark: .white.withAlphaComponent(0.18))
    /// Switch track when off.
    static let trackOff = Color(light: .lunaHex(0xDADCE0), dark: .lunaHex(0x48484D))

    static let columnWidth: CGFloat = 680
    static let cardRadius: CGFloat = 12
    static let rowHorizontalPadding: CGFloat = 16
}

// MARK: - Form hosting

private struct SettingsFormHostedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside a grouped `Form` (onboarding reuses a few settings sections): the kit then draws
    /// native Form sections and rows instead of cards.
    var settingsFormHosted: Bool {
        get { self[SettingsFormHostedKey.self] }
        set { self[SettingsFormHostedKey.self] = newValue }
    }
}

// MARK: - Page and card

/// A pane: large heading, then its cards, in a centered column that scrolls.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, 2)
                content
            }
            .frame(maxWidth: SettingsStyle.columnWidth, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .settingsControlStyles()
    }
}

/// A rounded card of rows with an optional heading above and note below. Rows are split by hairlines.
struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    @Environment(\.settingsFormHosted) private var formHosted

    var body: some View {
        if formHosted {
            Section {
                content
            } header: {
                if let title { Text(title) }
            } footer: {
                if let footer { Text(footer).foregroundStyle(.secondary) }
            }
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            SettingsHairline()
                        }
                        row
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous).fill(SettingsStyle.card))
            .overlay(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
                .strokeBorder(SettingsStyle.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsHairline: View {
    var body: some View {
        Rectangle().fill(SettingsStyle.hairline).frame(height: 1)
            .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
    }
}

// MARK: - Rows

/// Title and description on the left, `trailing` (the control) on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var icon: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, icon: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing()
    }

    @Environment(\.settingsFormHosted) private var formHosted

    var body: some View {
        if formHosted {
            LabeledContent {
                trailing
            } label: {
                Text(title)
                if let subtitle { Text(subtitle) }
            }
        } else {
            HStack(spacing: 16) {
                SettingsRowLabel(title: title, subtitle: subtitle, icon: icon)
                Spacer(minLength: 12)
                trailing
            }
            .settingsRowPadding()
        }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, icon: String? = nil) {
        self.init(title, subtitle: subtitle, icon: icon) { EmptyView() }
    }
}

/// The left side of a row.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?
    var icon: String?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Free content laid out with row padding (a note, a status line, a custom control).
struct SettingsContentRow<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsRowPadding()
    }
}

/// A secondary-text note row inside a card.
struct SettingsNoteRow: View {
    let text: String
    var isError = false

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsRowPadding(vertical: 10, minHeight: 0)
    }
}

/// A row with a switch; clicking anywhere on the row flips it.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    @Environment(\.settingsFormHosted) private var formHosted

    var body: some View {
        let toggle = Toggle(isOn: $isOn) {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
        if formHosted {
            toggle
        } else {
            toggle.toggleStyle(SettingsRowToggleStyle(title: title, subtitle: subtitle))
        }
    }
}

private struct SettingsRowToggleStyle: ToggleStyle {
    let title: String
    let subtitle: String?

    func makeBody(configuration: Configuration) -> some View {
        SettingsHoverRow(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 16) {
                SettingsRowLabel(title: title, subtitle: subtitle)
                Spacer(minLength: 12)
                SettingsSwitch(isOn: configuration.isOn)
            }
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { Text(title) }
                .accessibilityHint(subtitle ?? "")
        }
    }
}

/// Chrome's switch: accent track with a white knob when on, a grey track with a smaller knob when off.
struct SettingsSwitch: View {
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(isOn ? Color.accentColor : SettingsStyle.trackOff)
                .frame(width: 32, height: 18)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.18), radius: 0.8, y: 0.5)
                .frame(width: isOn ? 14 : 12, height: isOn ? 14 : 12)
                .padding(.horizontal, isOn ? 2 : 3)
        }
        .frame(width: 32, height: 18)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// A row with a Chrome-style dropdown (a `LunaMenu`, never a system pop-up).
struct SettingsMenuRow<Value: Hashable>: View {
    let title: String
    var subtitle: String?
    @Binding var selection: Value
    let options: [LunaPickerOption<Value>]

    init(_ title: String, subtitle: String? = nil, selection: Binding<Value>, options: [LunaPickerOption<Value>]) {
        self.title = title
        self.subtitle = subtitle
        self._selection = selection
        self.options = options
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            SettingsDropdown(title: title, selection: $selection, options: options)
        }
    }
}

/// The dropdown alone, for rows that hold more than one control.
struct SettingsDropdown<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [LunaPickerOption<Value>]
    var minWidth: CGFloat = 150

    var body: some View {
        let current = options.first { $0.value == selection }
        LunaMenuButton(alignment: .trailing, minWidth: minWidth, items: {
            options.enumerated().map { i, option in
                .item(LunaMenuItem(id: "opt.\(i)", title: option.title, icon: option.image.map { .image($0) },
                                   isChecked: option.value == selection, action: { selection = option.value }))
            }
        }) { isOpen in
            SettingsDropdownLabel(title: current?.title ?? "", image: current?.image, isOpen: isOpen, minWidth: minWidth)
        }
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(current?.title ?? "")
    }
}

/// Closed dropdown: value and a down chevron in a bordered rounded box.
struct SettingsDropdownLabel: View {
    let title: String
    var image: NSImage?
    var isOpen = false
    var minWidth: CGFloat = 150
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 14, height: 14)
            }
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .frame(minWidth: minWidth, minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isOpen ? LunaSurface.pressed : (hovering ? LunaSurface.hover : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(isOpen ? Color.accentColor.opacity(0.8) : LunaSurface.stroke.opacity(1.4), lineWidth: 1))
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
}

/// A row that opens something: a chevron (subpage) or an arrow (outside Luna) on the right.
struct SettingsLinkRow: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var external = false
    let action: () -> Void

    init(_ title: String, subtitle: String? = nil, icon: String? = nil, external: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.external = external
        self.action = action
    }

    @Environment(\.settingsFormHosted) private var formHosted

    var body: some View {
        if formHosted {
            LabeledContent {
                Button(external ? "Open" : "Show", action: action)
            } label: {
                Text(title)
                if let subtitle { Text(subtitle) }
            }
        } else {
            linkRow
        }
    }

    private var linkRow: some View {
        SettingsHoverRow(action: action) {
            HStack(spacing: 16) {
                SettingsRowLabel(title: title, subtitle: subtitle, icon: icon)
                Spacer(minLength: 12)
                Image(systemName: external ? "arrow.up.forward.square" : "chevron.right")
                    .font(.system(size: external ? 13 : 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
        .accessibilityAddTraits(external ? [.isButton, .isLink] : .isButton)
    }
}

/// A full-row button with a quick hover fill.
private struct SettingsHoverRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label
                .settingsRowPadding()
                .background(hovering && isEnabled ? LunaSurface.hover.opacity(0.6) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SettingsRowPadding: ViewModifier {
    let vertical: CGFloat
    let minHeight: CGFloat
    @Environment(\.settingsFormHosted) private var formHosted

    func body(content: Content) -> some View {
        if formHosted {
            content
        } else {
            content
                .padding(.horizontal, SettingsStyle.rowHorizontalPadding)
                .padding(.vertical, vertical)
                .frame(minHeight: minHeight)
        }
    }
}

extension View {
    /// Card row insets (none inside a Form).
    func settingsRowPadding(vertical: CGFloat = 11, minHeight: CGFloat = 50) -> some View {
        modifier(SettingsRowPadding(vertical: vertical, minHeight: minHeight))
    }

    /// Chrome-style buttons for everything inside a settings page.
    func settingsControlStyles() -> some View {
        buttonStyle(SettingsButtonStyle())
    }
}

// MARK: - Buttons

/// Chrome's outlined pill button: accent label, hairline border; red label for destructive actions.
struct SettingsButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct SettingsButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let destructive = configuration.role == .destructive
            let tint: Color = destructive ? .red : .accentColor
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(prominent ? Color.white : tint)
                .padding(.horizontal, 14)
                .frame(minHeight: 28)
                .background(Capsule(style: .circular).fill(
                    prominent ? tint.opacity(configuration.isPressed ? 0.8 : 1)
                        : tint.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.08 : 0))))
                .overlay(Capsule(style: .circular).inset(by: 0.5)
                    .stroke(prominent ? Color.clear : SettingsStyle.buttonBorder, lineWidth: 1))
                .contentShape(Capsule(style: .circular))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
    static var settingsProminent: SettingsButtonStyle { SettingsButtonStyle(prominent: true) }
}

// MARK: - Text fields

/// A Chrome-style bordered text field.
struct SettingsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsStyle.card))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(LunaSurface.stroke.opacity(1.4)))
    }
}

// MARK: - Tabs

/// Chrome-style tabs inside a pane: titles with an accent underline under the selected one.
struct SettingsTabBar<Value: Hashable>: View {
    @Binding var selection: Value
    let tabs: [(Value, String)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs.indices, id: \.self) { i in
                    TabButton(title: tabs[i].1, isSelected: tabs[i].0 == selection) { selection = tabs[i].0 }
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(SettingsStyle.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private struct TabButton: View {
        let title: String
        let isSelected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 0) {
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : (hovering ? Color.primary : Color.secondary))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                        .frame(height: 3)
                        .padding(.horizontal, 8)
                }
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// The bare Chrome switch as a `ToggleStyle`, for toggles inside custom rows.
struct SettingsSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { SettingsSwitch(isOn: configuration.isOn) }
            .buttonStyle(.plain)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A row with a segmented control on the right.
struct SettingsSegmentedRow<Value: Hashable>: View {
    let title: String
    var subtitle: String?
    @Binding var selection: Value
    let options: [LunaPickerOption<Value>]

    init(_ title: String, subtitle: String? = nil, selection: Binding<Value>, options: [LunaPickerOption<Value>]) {
        self.title = title
        self.subtitle = subtitle
        self._selection = selection
        self.options = options
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            LunaSegmentedPicker(title, selection: $selection, options: options)
                .labelsHidden()
                .fixedSize()
        }
    }
}
