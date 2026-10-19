// Axolotl — ASCII axolotl for the start page and the AI panel (the brand mark, drawn as pre-rendered glyphs).
// The AxolotlMark artwork is sampled once into a glyph grid; a light sweep runs across it, the
// gills shimmer pink, and the head bobs. Pauses off screen and under Reduce Motion.
import SwiftUI
import AppKit

struct AsciiAxolotl: View {
    /// The view is diameter × 1.3 wide and × 1.15 tall.
    var diameter: CGFloat = 170
    /// Sweeps faster while the AI is working.
    var isBusy: Bool = false
    /// Characters, colors and motion; the start page passes the user's choice.
    var style = LogoStyle()

    @State private var clock = AsciiClock()
    @State private var onScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Still: one frame, then the paused timeline costs nothing.
        let animating = onScreen && !reduceMotion && style.motion == .wave
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { tl in
            Canvas { ctx, size in
                let t = animating ? clock.advance(tl.date, busy: isBusy) : clock.hold()
                AxolotlRenderer.draw(&ctx, size: size, diameter: diameter, t: t, style: style)
            }
        }
        .frame(width: diameter * 1.3, height: diameter * 1.15)
        .background(WindowVisibilityReader(isVisible: $onScreen))
        .onDisappear { onScreen = false }
        .accessibilityHidden(true)
    }
}

extension LogoStyle.Glyphs {
    var title: String {
        switch self {
        case .classic: return "Classic"
        case .blocks: return "Blocks"
        case .dots: return "Dots"
        case .binary: return "Binary"
        case .letters: return "Letters"
        }
    }

    /// Dim to bright, except `letters`, which spells AXOLOTL across the grid.
    var ramp: [String] {
        switch self {
        case .classic: return AsciiGlyphs.ramp
        case .blocks: return ["░", "▒", "▓", "█"]
        case .dots: return ["·", "•", "●"]
        case .binary: return ["0", "1"]
        case .letters: return "AXOLOTL".map(String.init)
        }
    }
}

extension LogoStyle.Tint {
    var title: String { rawValue.capitalized }

    /// Body and gill colors.
    var colors: [NSColor] {
        switch self {
        case .classic: return [NSColor(red: 0.96, green: 0.95, blue: 0.90, alpha: 1), // cream body
                               NSColor(red: 0.95, green: 0.68, blue: 0.75, alpha: 1)] // pink gills
        case .accent:
            // Resolved to fixed components so the glyph cache key changes with the accent.
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            return [accent.blended(withFraction: 0.35, of: .white) ?? accent, accent]
        case .mono: return [NSColor(white: 0.92, alpha: 1), NSColor(white: 0.68, alpha: 1)]
        case .pink: return [NSColor(red: 1.00, green: 0.62, blue: 0.76, alpha: 1), NSColor(red: 0.90, green: 0.36, blue: 0.62, alpha: 1)]
        case .gold: return [NSColor(red: 1.00, green: 0.84, blue: 0.48, alpha: 1), NSColor(red: 0.93, green: 0.62, blue: 0.24, alpha: 1)]
        }
    }
}

extension LogoStyle.Size {
    var title: String { rawValue.capitalized }
    var scale: CGFloat {
        switch self {
        case .small: return 0.75
        case .medium: return 1
        case .large: return 1.25
        }
    }
}

enum AxolotlRenderer {

    /// Artwork coverage (alpha × brightness, 0...1) per glyph cell, row-major.
    struct Grid: Equatable { let cols: Int, rows: Int, cells: [Float] }
    private static var grids: [String: Grid] = [:]

    /// Samples the AxolotlMark artwork into `cols` × `rows` cells, centered and fit to the grid.
    static func grid(cols: Int, rows: Int, cellAspect: CGFloat) -> Grid {
        let key = "\(cols)x\(rows)x\(cellAspect)"
        if let g = grids[key] { return g }
        var cells = [Float](repeating: 0, count: cols * rows)
        if let art = NSImage(named: "AxolotlMark"), cols > 0, rows > 0,
           let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cols, pixelsHigh: rows, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: cols * 4, bitsPerPixel: 32) {
            // Cells are taller than wide (cellAspect = height / width), so fit the art in "square" units.
            let gw = CGFloat(cols), gh = CGFloat(rows) * cellAspect
            let scale = min(gw * 0.94 / art.size.width, gh * 0.94 / art.size.height)
            let w = art.size.width * scale, h = art.size.height * scale / cellAspect
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            art.draw(in: NSRect(x: (gw - w) / 2, y: (CGFloat(rows) - h) / 2, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            if let px = rep.bitmapData {
                for r in 0..<rows {
                    for c in 0..<cols {
                        let i = (r * cols + c) * 4
                        // Premultiplied red is alpha × brightness for the cream artwork.
                        cells[r * cols + c] = Float(px[i]) / 255
                    }
                }
            }
        }
        let g = Grid(cols: cols, rows: rows, cells: cells)
        grids[key] = g
        return g
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, diameter: CGFloat, t: Float, style: LogoStyle = LogoStyle()) {
        let ramp = style.glyphs.ramp
        // Fine glyphs so the eyes and smile survive sampling.
        let fs = max(5, diameter / 24)
        let cw = fs * 0.62, ch = fs * 1.12
        let atlas = style.tint.colors.map { color in ramp.map { ctx.resolve(Image(nsImage: AsciiGlyphs.glyph($0, size: fs, color: color))) } }
        let cols = Int(size.width / cw), rows = Int(size.height / ch)
        let g = grid(cols: cols, rows: rows, cellAspect: ch / cw)
        let bob = CGFloat(sinf(t * 0.9)) * ch * 0.3

        for r in 0..<rows {
            for c in 0..<cols {
                // Contrast curve: partly covered cells (eyes, smile, edges) drop off so features read.
                let v = powf(g.cells[r * cols + c], 2.4)
                guard v > 0.04 else { continue }
                let nx = (Float(c) + 0.5) / Float(cols) * 2 - 1
                let ny = (Float(r) + 0.5) / Float(rows) * 2 - 1
                // A soft light band sweeping diagonally, plus a faster shimmer on the gills.
                let gill = abs(nx) > 0.52
                let sweep = 0.5 + 0.5 * sinf(nx * 2.4 + ny * 1.3 - t * 1.1)
                let shimmer: Float = gill ? 0.15 * sinf(t * 2.3 + ny * 6 + abs(nx) * 5) : 0
                let lit = min(1, v * (0.72 + 0.28 * sweep + shimmer))
                let glyph = style.glyphs == .letters ? (r * cols + c) % ramp.count
                                                     : min(ramp.count - 1, Int(lit * Float(ramp.count)))
                ctx.opacity = Double(0.35 + 0.65 * lit)
                let x = (CGFloat(c) + 0.5) * cw, y = (CGFloat(r) + 0.5) * ch + (gill ? bob * 1.3 : bob)
                ctx.draw(atlas[gill ? 1 : 0][glyph], at: CGPoint(x: x, y: y), anchor: .center)
            }
        }
    }
}
