// Axolotl — Settings › Appearance › Wallpaper.
import SwiftUI
import AppKit

struct WallpaperSettingsSection: View {
    @ObservedObject private var store = WallpaperStore.shared

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 132), spacing: 12)]

    var body: some View {
        SettingsCard("Wallpaper", footer: store.preset != .none
                     ? "Wallpapers draw only while a start page is on screen, and hold still with Reduce Motion or Low Power Mode."
                     : nil) {
            SettingsContentRow {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(WallpaperPreset.allCases) { preset in
                    WallpaperTile(preset: preset,
                                  gradient: gradientColors(for: preset),
                                  isSelected: store.preset == preset) {
                        store.preset = preset
                    }
                }
            }
            .padding(.vertical, 4)
            }

            SettingsMenuRow("Moon style", subtitle: "Shader draws a softly lit moon with the GPU.",
                            selection: $store.moonStyle, options: MoonStyle.allCases.map { .init($0, $0.title) })

            if store.preset != .none {
                styleControls(for: store.preset)
            }
        }
    }

    private func gradientColors(for preset: WallpaperPreset) -> [Color] {
        let id = store.style(for: preset).palette
        let palette = WallpaperPalette.all.first { $0.id == id } ?? WallpaperPalette.all[0]
        return [palette.base, palette.mid, palette.high].map { Color(hex: $0) }
    }

    @ViewBuilder
    private func styleControls(for preset: WallpaperPreset) -> some View {
        let style = Binding(get: { store.style(for: preset) },
                            set: { store.setStyle($0, for: preset) })

        SettingsRow("Palette") {
            HStack(spacing: 8) {
                ForEach(WallpaperPalette.all) { palette in
                    SwatchButton(colors: [palette.base, palette.mid, palette.high],
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
                    SwatchButton(colors: [accent.hex], name: accent.name,
                                 isSelected: style.wrappedValue.accent == accent.id) {
                        style.wrappedValue.accent = accent.id
                    }
                }
            }
        }
        sliderRow("Speed", value: style.speed, in: WallpaperStyle.speedRange,
                  label: { String(format: "%.2g×", $0) })
        sliderRow("Intensity", value: style.intensity, in: WallpaperStyle.intensityRange,
                  label: { "\(Int(($0 * 100).rounded()))%" })
        sliderRow("Dim", value: style.dim, in: WallpaperStyle.dimRange,
                  label: { "\(Int(($0 * 100).rounded()))%" })

        SettingsToggleRow("Show moon on top", subtitle: "Keep the moon above the greeting while a wallpaper is on.",
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
    let gradient: [Color]
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(white: 0.08))
                    if preset == .none {
                        Image(systemName: "moon.stars")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        // Palette gradient, not a live render: no web view per tile.
                        LinearGradient(colors: gradient, startPoint: .bottomLeading, endPoint: .topTrailing)
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

private struct SwatchButton: View {
    let colors: [String]
    let name: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Circle()
                .fill(LinearGradient(colors: colors.map { Color(hex: $0) },
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
