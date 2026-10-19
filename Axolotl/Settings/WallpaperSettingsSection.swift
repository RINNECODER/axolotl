// Axolotl — Settings › Appearance › Wallpaper.
import SwiftUI
import AppKit

struct WallpaperSettingsSection: View {
    @ObservedObject private var store = WallpaperStore.shared

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 132), spacing: 12)]

    var body: some View {
        SettingsCard("Wallpaper", footer: store.preset != .none
                     ? "Wallpapers draw only while a start page is on screen, and hold still with no pointer effects in Reduce Motion or Low Power Mode."
                     : nil) {
            SettingsContentRow {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(WallpaperPreset.allCases) { preset in
                    WallpaperTile(preset: preset, isSelected: store.preset == preset) {
                        store.preset = preset
                    }
                }
            }
            .padding(.vertical, 4)
            }
            SettingsRow("Surprise me", subtitle: "A random wallpaper, colors and look.") {
                Button("Surprise Me") { store.surpriseMe() }
            }

            if store.preset != .none {
                styleControls(for: store.preset)
            }
        }
        logoCard
    }

    private var logoCard: some View {
        SettingsCard("Start page logo") {
            SettingsToggleRow("Show logo", subtitle: "The axolotl above the greeting.", isOn: $store.logo.show)
            if store.logo.show {
                SettingsContentRow { LogoPreview(style: store.logo) }
                SettingsRow("Characters") {
                    HStack(spacing: 6) {
                        ForEach(LogoStyle.Glyphs.allCases, id: \.self) { glyphs in
                            GlyphsButton(glyphs: glyphs, isSelected: store.logo.glyphs == glyphs) { store.logo.glyphs = glyphs }
                        }
                    }
                }
                SettingsRow("Colors") {
                    HStack(spacing: 8) {
                        ForEach(LogoStyle.Tint.allCases, id: \.self) { tint in
                            SwatchButton(colors: tint.colors.map { Color(nsColor: $0) }, name: tint.title,
                                         isSelected: store.logo.tint == tint) { store.logo.tint = tint }
                        }
                    }
                }
                SettingsMenuRow("Size", selection: $store.logo.size,
                                options: LogoStyle.Size.allCases.map { .init($0, $0.title) })
                SettingsMenuRow("Motion", subtitle: "Still draws once and stops. Reduce Motion always holds it still.",
                                selection: $store.logo.motion, options: [.init(.wave, "Wave"), .init(.still, "Still")])
            }
        }
    }

    @ViewBuilder
    private func styleControls(for preset: WallpaperPreset) -> some View {
        let style = Binding(get: { store.style(for: preset) },
                            set: { store.setStyle($0, for: preset) })

        SettingsRow("Palette") {
            HStack(spacing: 8) {
                ForEach(WallpaperPalette.all) { palette in
                    SwatchButton(colors: [palette.base, palette.mid, palette.high].map { Color(hex: $0) },
                                 name: palette.name,
                                 isSelected: style.wrappedValue.palette == palette.id) {
                        style.wrappedValue.palette = palette.id
                    }
                }
            }
        }
        SettingsRow("Accent") {
            HStack(spacing: 8) {
                ForEach(WallpaperAccent.all) { accent in
                    SwatchButton(colors: [Color(hex: accent.hex)], name: accent.name,
                                 isSelected: style.wrappedValue.accent == accent.id) {
                        style.wrappedValue.accent = accent.id
                    }
                }
            }
        }
        sliderRow("Speed", value: style.speed, in: WallpaperStyle.speedRange,
                  label: { $0 == 0 ? "Still" : String(format: "%.2g×", $0) })
        sliderRow("Intensity", value: style.intensity, in: WallpaperStyle.intensityRange,
                  label: { "\(Int(($0 * 100).rounded()))%" })
        sliderRow("Dim", value: style.dim, in: WallpaperStyle.dimRange,
                  label: { "\(Int(($0 * 100).rounded()))%" })
        sliderRow("Grain", value: style.grain, in: WallpaperStyle.grainRange,
                  label: { "\(Int(($0 * 100).rounded()))%" })
        sliderRow("Zoom", value: style.zoom, in: WallpaperStyle.zoomRange,
                  label: { String(format: "%.2g×", $0) })
        SettingsMenuRow("Pointer", subtitle: "How the wallpaper follows the pointer on the start page.",
                        selection: style.pointer,
                        options: [.init(.off, "Off"), .init(.glow, "Glow"), .init(.ripple, "Ripple"), .init(.parallax, "Parallax")])
        SettingsMenuRow("Click", selection: style.click, options: [.init(.off, "Off"), .init(.burst, "Burst")])

        SettingsToggleRow("Show logo on top", subtitle: "Keep the logo above the greeting while a wallpaper is on.",
                          isOn: $store.showMoon)
        SettingsMenuRow("Frame rate", selection: $store.frameRate, options: [.init(30, "30 fps"), .init(60, "60 fps")])
        SettingsRow("Reset \(preset.title)", subtitle: "Back to this wallpaper's default look.") {
            Button("Reset") { store.resetStyle(for: preset) }
                .disabled(store.style(for: preset) == preset.defaultStyle)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           label: @escaping (Double) -> String) -> some View {
        SettingsRow(title) {
            HStack {
                Slider(value: value, in: range)
                    .frame(width: 200)
                Text(label(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

private struct WallpaperTile: View {
    let preset: WallpaperPreset
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(white: 0.08))
                    if preset == .none {
                        Image("AxolotlMark").renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 30)
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        // Pre-rendered by scripts/wallpaper/thumbs.mjs: no web view per tile.
                        Color.clear.overlay(Image("wallpaper-\(preset.rawValue)").resizable().scaledToFill())
                    }
                }
                .frame(height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: isSelected ? 2 : 1)
                )
                Text(preset.title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small live logo, drawn like the start page; it holds still while scrolled out of view.
private struct LogoPreview: View {
    let style: LogoStyle
    @State private var inView = true

    var body: some View {
        var shown = style
        if !inView { shown.motion = .still }
        return AsciiAxolotl(diameter: 64 * style.size.scale, style: shown)
            .frame(maxWidth: .infinity, minHeight: 64 * 1.25 * 1.15)
            .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onScrollVisibilityChange(threshold: 0.05) { inView = $0 }
    }
}

private struct GlyphsButton: View {
    let glyphs: LogoStyle.Glyphs
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Text(glyphs.ramp.prefix(4).joined())
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 44, height: 22)
                .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .foregroundStyle(.white.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(glyphs.title)
        .accessibilityLabel(glyphs.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SwatchButton: View {
    let colors: [Color]
    let name: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Circle()
                .fill(LinearGradient(colors: colors,
                                     startPoint: .bottomLeading, endPoint: .topTrailing))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .padding(2)
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension Color {
    init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }
}
