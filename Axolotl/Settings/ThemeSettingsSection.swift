import SwiftUI

/// Settings → Appearance → Theme and Liquid Glass. Every control writes a `CustomizationRegistry` setting,
/// so people and agents change the same values. Colors are swatches; the hex field is optional.
struct ThemeSettingsSection: View {
    @Environment(\.colorScheme) private var scheme
    /// Which variant the swatches show and the hex fields edit.
    @State private var editingDark: Bool?
    @State private var glassExpanded = false

    private var dark: Bool { editingDark ?? (scheme == .dark) }

    var body: some View {
        let theme = ThemeStore.shared.theme
        let glass = ThemeStore.shared.glass
        Group {
            SettingsCard("Theme", footer: "Picking a color shows Custom. Swatches set the light and dark color together; "
                         + "the hex field changes only the one shown.") {
                RegistryPicker("appearance.theme")
                SettingsContentRow { ThemePresetPicker(current: theme.preset, dark: dark) }
                SettingsSegmentedRow("Colors for", selection: Binding(get: { dark }, set: { editingDark = $0 }),
                                     options: [.init(false, "Light"), .init(true, "Dark")])
                ThemeColorRow(token: .accent, swatches: ThemeSwatches.accents, theme: theme, dark: dark)
                ForEach([ThemeColorToken.window, .sidebar, .toolbar, .activeTab]) { token in
                    ThemeColorRow(token: token, swatches: ThemeSwatches.backgrounds(token), theme: theme, dark: dark)
                }
                RegistryPicker("appearance.density")
                RegistryIntPicker("appearance.cornerRadius")
                RegistryIntPicker("appearance.fontScale")
                RegistryPicker("appearance.contrast")
            }

            SettingsCard("Liquid Glass", footer: glass.master ? nil : "Turn Liquid Glass on to choose where it's used.") {
                RegistryToggle("appearance.liquidGlass")
                if glass.master {
                    SettingsRow("Customize", subtitle: "Choose glass for each part of the window, and its blur and tint.") {
                        Button { withAnimation(.easeInOut(duration: 0.15)) { glassExpanded.toggle() } } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(glassExpanded ? 180 : 0))
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(glassExpanded ? "Hide glass options" : "Show glass options")
                    }
                    if glassExpanded {
                        ForEach(GlassSurface.allCases) { RegistryToggle($0.registryKey) }
                        RegistryToggle("glass.blur")
                        RegistryIntPicker("glass.tint")
                    }
                }
            }
        }
    }
}

/// Writes a theme registry setting from Settings (a layout template becomes Custom, like other managed settings).
private func writeTheme(_ key: String, _ value: JSONValue) {
    RegistrySettings.willChange("appearance.themePreset")
    CustomizationRegistry.setting(key)?.write(.live, value)
}

/// One swatch per preset: its window color with the accent as a dot.
private struct ThemePresetPicker: View {
    let current: ThemePreset?
    let dark: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(ThemePreset.allCases) { preset in
                Button { writeTheme("appearance.themePreset", .string(preset.rawValue)) } label: {
                    swatch(title: preset.title, selected: current == preset) {
                        ZStack(alignment: .topLeading) {
                            Color(axolotlHex: preset.color(.window).hex(dark: dark))
                            Color(axolotlHex: preset.color(.toolbar).hex(dark: dark)).frame(height: 12)
                            RoundedRectangle(cornerRadius: 3).fill(Color(axolotlHex: preset.color(.activeTab).hex(dark: dark)))
                                .frame(width: 22, height: 9).offset(x: 6, y: 3)
                            Circle().fill(Color(axolotlHex: preset.color(.accent).hex(dark: dark)))
                                .frame(width: 11, height: 11).offset(x: 34, y: 24)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(preset.title) theme")
                .accessibilityAddTraits(current == preset ? .isSelected : [])
            }
            if current == nil {
                swatch(title: "Custom", selected: true) {
                    Image(systemName: "paintpalette").font(.system(size: 16)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .accessibilityLabel("Custom theme")
            }
        }
    }

    private func swatch<V: View>(title: String, selected: Bool, @ViewBuilder content: () -> V) -> some View {
        VStack(spacing: 5) {
            content()
                .frame(width: 56, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AxolotlSurface.stroke))
                .padding(2.5)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? AxolotlSurface.accent : .clear, lineWidth: 2))
            Text(title).font(.system(size: 11.5)).foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
    }
}

/// A theme color: swatches, then an optional hex field for the variant being edited.
private struct ThemeColorRow: View {
    let token: ThemeColorToken
    let swatches: [ThemeColorPair]
    let theme: Theme
    let dark: Bool
    @State private var hex = ""
    @State private var invalid = false

    private var value: UInt32 { theme.pair(token).hex(dark: dark) }

    var body: some View {
        SettingsRow(token.title, subtitle: token.summary) {
            HStack(spacing: 6) {
                ForEach(swatches.indices, id: \.self) { i in
                    let pair = swatches[i]
                    // Several swatches can share the shown variant; ring only the first.
                    let selected = swatches.firstIndex { $0.hex(dark: dark) == value } == i
                    Button {
                        writeTheme(token.registryKey(dark: false), .string(ThemeHex.format(pair.light)))
                        writeTheme(token.registryKey(dark: true), .string(ThemeHex.format(pair.dark)))
                    } label: {
                        Circle().fill(Color(axolotlHex: pair.hex(dark: dark)))
                            .overlay(Circle().strokeBorder(AxolotlSurface.stroke))
                            .frame(width: 18, height: 18)
                            .padding(2)
                            .overlay(Circle().strokeBorder(selected ? AxolotlSurface.accent : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(token.title) \(ThemeHex.format(pair.hex(dark: dark)))")
                }
                TextField("Hex", text: $hex)
                    .textFieldStyle(SettingsTextFieldStyle())
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 84)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(invalid ? .red : .clear))
                    .onSubmit(commit)
                    .accessibilityLabel("\(token.title) hex color (\(dark ? "dark" : "light"))")
            }
        }
        .onAppear { hex = ThemeHex.format(value) }
        .onChange(of: value) { _, v in hex = ThemeHex.format(v); invalid = false }
        .onChange(of: dark) { _, _ in hex = ThemeHex.format(value); invalid = false }
    }

    private func commit() {
        guard let v = ThemeHex.parse(hex) else { invalid = true; return }
        invalid = false
        writeTheme(token.registryKey(dark: dark), .string(ThemeHex.format(v)))
        hex = ThemeHex.format(v)
    }
}
