import SwiftUI

/// Dev mode's look. The structure (neutral canvas, hairline borders, one accent, a small type
/// ramp) follows T3 Code's chat (https://github.com/pingdotgg/t3code, MIT License,
/// apps/web/src/index.css); the colors are Luna's own: a cool "night sky" neutral scale, the
/// accent from Settings → Dev → Appearance (Moonlight by default), and Luna's serif
/// (`LunaType.brand`) for titles.
struct DevPalette {
    let background: Color
    let foreground: Color
    let card: Color
    let mutedForeground: Color
    /// Hover fills and the user message surface.
    let accent: Color
    let muted: Color
    let border: Color
    let input: Color
    /// The user's accent (Settings → Dev → Appearance).
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

    /// The accent at low strength (selected chips, user bubbles, badges).
    var primarySoft: Color { primary.opacity(isDark ? 0.18 : 0.11) }

    /// Light: paper white with a faint blue cast.
    static func light(_ accent: DevAccent) -> DevPalette {
        let a = accent.colors
        return DevPalette(
            background: Color(hex: 0xFBFBFD), foreground: Color(hex: 0x23252D), card: .white,
            mutedForeground: Color(hex: 0x6E7280), accent: Color(hex: 0xF1F2F6), muted: Color(hex: 0xF8F8FB),
            border: Color(hex: 0xE3E4EB), input: Color(hex: 0xD3D5DE),
            primary: a.light, primaryForeground: .white,
            composerOutline: Color.black.opacity(0.07),
            warning: Color(hex: 0xF59E0B), warningForeground: Color(hex: 0xB45309),
            error: Color(hex: 0xEF4444), errorForeground: Color(hex: 0xB91C1C),
            errorSurface: Color(hex: 0xEF4444).opacity(0.08), success: Color(hex: 0x10B981), isDark: false)
    }

    /// Dark: a blue-black night sky, surfaces lifted with cool white.
    static func dark(_ accent: DevAccent) -> DevPalette {
        let a = accent.colors
        return DevPalette(
            background: Color(hex: 0x0B0C10), foreground: Color(hex: 0xEEF0F5), card: Color(hex: 0x12141A),
            mutedForeground: Color(hex: 0x8A8E9C), accent: Color(red: 0.85, green: 0.89, blue: 1).opacity(0.07),
            muted: Color.white.opacity(0.03),
            border: Color(red: 0.85, green: 0.89, blue: 1).opacity(0.075), input: Color.white.opacity(0.09),
            primary: a.dark, primaryForeground: a.onDark,
            composerOutline: Color.white.opacity(0.08),
            warning: Color(hex: 0xF59E0B), warningForeground: Color(hex: 0xFBBF24),
            error: Color(hex: 0xF15A5A), errorForeground: Color(hex: 0xF87171),
            errorSurface: Color(hex: 0xF15A5A).opacity(0.16), success: Color(hex: 0x34D399), isDark: true)
    }

    /// The palette for `scheme` with the current accent. Reading it in a view body observes
    /// `DevSettings.accent`, so accent changes apply live.
    static func of(_ scheme: ColorScheme, accent: DevAccent? = nil) -> DevPalette {
        let accent = accent ?? DevSettings.shared.accent
        return scheme == .dark ? .dark(accent) : .light(accent)
    }

    /// General mode's palette (its dark glass panel and `ChatTokens`), for controls such as the
    /// composer's mode menu that share Dev's dropdown.
    static var general: DevPalette {
        DevPalette(
            background: Color(white: 0.09), foreground: ChatTokens.textPrimary, card: Color(white: 0.12),
            mutedForeground: ChatTokens.textSecondary, accent: Color.white.opacity(0.07), muted: Color.white.opacity(0.03),
            border: Color.white.opacity(0.08), input: Color.white.opacity(0.1),
            primary: ChatTokens.accent, primaryForeground: .white,
            composerOutline: Color.white.opacity(0.08),
            warning: Color(hex: 0xF59E0B), warningForeground: Color(hex: 0xFBBF24),
            error: Color(hex: 0xF15A5A), errorForeground: ChatTokens.errorText,
            errorSurface: Color(hex: 0xF15A5A).opacity(0.16), success: Color(hex: 0x34D399), isDark: true)
    }
}

extension DevAccent {
    /// Swatch colors: the light-mode tone, the dark-mode tone, and the text on the dark tone.
    var colors: (light: Color, dark: Color, onDark: Color) {
        switch self {
        case .moon: return (Color(hex: 0x4D6A93), Color(hex: 0x9FB4D8), Color(hex: 0x0B0C10))
        case .blue: return (Color(hex: 0x2F62E9), Color(hex: 0x5B8BF7), .white)
        case .violet: return (Color(hex: 0x7C4DEB), Color(hex: 0xA58BFA), Color(hex: 0x0B0C10))
        case .green: return (Color(hex: 0x0E8A6A), Color(hex: 0x3CCB9C), Color(hex: 0x0B0C10))
        case .orange: return (Color(hex: 0xD9680F), Color(hex: 0xF59F4C), Color(hex: 0x0B0C10))
        case .pink: return (Color(hex: 0xD0417F), Color(hex: 0xF07AAE), Color(hex: 0x0B0C10))
        case .graphite: return (Color(hex: 0x4F535C), Color(hex: 0xB5BAC5), Color(hex: 0x0B0C10))
        }
    }
}

/// Radii, the type ramp (scaled by Settings → Dev → Text size) and spacing (by Density).
enum DevMetrics {
    static let radiusSm: CGFloat = 7
    static let radiusMd: CGFloat = 9
    static let radiusLg: CGFloat = 12
    static let radius2xl: CGFloat = 18
    static let radius3xl: CGFloat = 24

    static var scale: CGFloat { CGFloat(DevSettings.shared.fontScale.factor) }
    static var compact: Bool { DevSettings.shared.density == .compact }

    /// Body / small / caption sizes.
    static var textSm: CGFloat { 13.5 * scale }
    static var textXs: CGFloat { 12 * scale }
    static var text2xs: CGFloat { 11 * scale }
    static func text(_ size: CGFloat) -> CGFloat { size * scale }

    /// Gap between timeline rows.
    static var rowSpacing: CGFloat { compact ? 9 : 15 }
    /// Horizontal inset of the timeline.
    static var gutter: CGFloat { compact ? 12 : 16 }
    /// Height of header / chip controls.
    static var controlHeight: CGFloat { compact ? 24 : 27 }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// A ghost control: muted label, accent fill on hover.
struct DevGhostButtonStyle: ButtonStyle {
    var palette: DevPalette
    var radius: CGFloat = DevMetrics.radiusMd

    func makeBody(configuration: Configuration) -> some View {
        DevHover(palette: palette, radius: radius, pressed: configuration.isPressed) { configuration.label }
    }
}

/// Small buttons: `primary` is an accent capsule, `outline` a bordered card capsule.
struct DevButtonStyle: ButtonStyle {
    enum Variant { case primary, outline }
    var palette: DevPalette
    var variant: Variant

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DevMetrics.textXs, weight: .medium))
            .foregroundStyle(variant == .primary ? palette.primaryForeground : palette.foreground)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule(style: .continuous).fill(variant == .primary ? palette.primary : palette.card))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(variant == .primary ? Color.clear : palette.input, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

private struct DevHover<Label: View>: View {
    let palette: DevPalette
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

/// A round icon control (header and composer).
struct DevIconButton: View {
    let systemName: String
    let help: String
    var palette: DevPalette
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .regular))
                .frame(width: 26, height: 26)
                .background(Circle().fill(isOn ? palette.accent : .clear))
        }
        .buttonStyle(DevGhostButtonStyle(palette: palette, radius: 13))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Luna's crescent: a circle with an offset circle cut out. Used small (header mark, empty
/// states, the home view) so the brand shows without decoration.
struct DevCrescent: Shape {
    /// How far the cut-out circle is shifted, as a fraction of the diameter.
    var phase: CGFloat = 0.32

    func path(in rect: CGRect) -> Path {
        let d = min(rect.width, rect.height)
        let disc = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        let cut = disc.offsetBy(dx: d * phase, dy: -d * phase * 0.55)
        return Path(ellipseIn: disc).subtracting(Path(ellipseIn: cut))
    }
}

/// The crescent mark in the accent color.
struct DevMoonMark: View {
    var size: CGFloat = 12
    var palette: DevPalette

    var body: some View {
        DevCrescent()
            .fill(LinearGradient(colors: [palette.primary, palette.primary.opacity(0.65)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
