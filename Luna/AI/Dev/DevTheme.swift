import SwiftUI

/// Dev mode's look, copied from T3 Code (https://github.com/pingdotgg/t3code, MIT License,
/// apps/web/src/index.css): its light and dark tokens, radii and type scale.
struct T3Palette {
    let background: Color
    let foreground: Color
    let card: Color
    let mutedForeground: Color
    /// Hover fills and the user message surface (`--accent` / `--message-surface`).
    let accent: Color
    let muted: Color
    let border: Color
    let input: Color
    let primary: Color
    let primaryForeground: Color
    let composerOutline: Color
    let warning: Color
    let warningForeground: Color
    let error: Color
    let errorForeground: Color
    let errorSurface: Color
    let success: Color
    let isDark: Bool

    /// `:root` (zinc scale, oklch primary 0.488 0.217 264).
    static let light = T3Palette(
        background: Color(hex: 0xFCFCFC), foreground: Color(hex: 0x27272A), card: .white,
        mutedForeground: Color(hex: 0x71717A), accent: Color(hex: 0xF4F4F5), muted: Color(hex: 0xFAFAFA),
        border: Color(hex: 0xE4E4E7), input: Color(hex: 0xD4D4D8),
        primary: Color(hex: 0x1B4ED8), primaryForeground: .white,
        composerOutline: Color.black.opacity(0.08),
        warning: Color(hex: 0xF59E0B), warningForeground: Color(hex: 0xB45309),
        error: Color(hex: 0xEF4444), errorForeground: Color(hex: 0xB91C1C),
        errorSurface: Color(hex: 0xEF4444).opacity(0.08), success: Color(hex: 0x10B981), isDark: false)

    /// `@variant dark` (neutral-950 canvas, surfaces 3% white, oklch primary 0.571 0.21 264).
    static let dark = T3Palette(
        background: Color(hex: 0x0A0A0A), foreground: Color(hex: 0xF5F5F5), card: Color(hex: 0x111111),
        mutedForeground: Color(hex: 0x818181), accent: Color.white.opacity(0.06), muted: Color.white.opacity(0.03),
        border: Color.white.opacity(0.06), input: Color.white.opacity(0.08),
        primary: Color(hex: 0x346BF1), primaryForeground: .white,
        composerOutline: Color.white.opacity(0.07),
        warning: Color(hex: 0xF59E0B), warningForeground: Color(hex: 0xFBBF24),
        error: Color(hex: 0xF15A5A), errorForeground: Color(hex: 0xF87171),
        errorSurface: Color(hex: 0xF15A5A).opacity(0.16), success: Color(hex: 0x10B981), isDark: true)

    static func of(_ scheme: ColorScheme) -> T3Palette { scheme == .dark ? .dark : .light }
}

/// T3's radius scale (`--radius: 0.625rem`) and the sizes its chat uses.
enum T3Metrics {
    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 10
    static let radius2xl: CGFloat = 16
    static let radius3xl: CGFloat = 24
    /// text-sm / text-xs / text-2xs.
    static let textSm: CGFloat = 14
    static let textXs: CGFloat = 12
    static let text2xs: CGFloat = 11
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// A T3 ghost control: muted label, accent fill on hover (`hover:bg-accent`).
struct T3GhostButtonStyle: ButtonStyle {
    var palette: T3Palette
    var radius: CGFloat = T3Metrics.radiusMd

    func makeBody(configuration: Configuration) -> some View {
        T3Hover(palette: palette, radius: radius, pressed: configuration.isPressed) { configuration.label }
    }
}

/// T3's xs button: `default` is the primary fill, `outline` a bordered card surface.
struct T3ButtonStyle: ButtonStyle {
    enum Variant { case primary, outline }
    var palette: T3Palette
    var variant: Variant

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: T3Metrics.textXs, weight: .medium))
            .foregroundStyle(variant == .primary ? palette.primaryForeground : palette.foreground)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: T3Metrics.radiusMd, style: .continuous)
                    .fill(variant == .primary ? palette.primary : palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: T3Metrics.radiusMd, style: .continuous)
                    .strokeBorder(variant == .primary ? Color.clear : palette.input, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: T3Metrics.radiusMd))
    }
}

private struct T3Hover<Label: View>: View {
    let palette: T3Palette
    let radius: CGFloat
    let pressed: Bool
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        label()
            .foregroundStyle(hovering ? palette.foreground : palette.mutedForeground)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering || pressed ? palette.accent : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .onHover { hovering = $0 }
    }
}

/// A square icon control from T3's header (size-7 ghost icon button).
struct T3IconButton: View {
    let systemName: String
    let help: String
    var palette: T3Palette
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: T3Metrics.radiusMd).fill(isOn ? palette.accent : .clear))
        }
        .buttonStyle(T3GhostButtonStyle(palette: palette))
        .help(help)
        .accessibilityLabel(help)
    }
}
