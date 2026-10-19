// Axolotl — ASCII axolotl for the start page and the AI panel (the brand mark, drawn like `AsciiMoon`).
// The AxolotlMark artwork is sampled once into a glyph grid; a light sweep runs across it, the
// gills shimmer pink, and the head bobs. Same frame and pause rules as the moon.
import SwiftUI
import AppKit

struct AsciiAxolotl: View {
    /// Same meaning as `AsciiMoon.diameter`: the view is diameter × 1.3 wide and × 1.15 tall.
    var diameter: CGFloat = 170
    /// Sweeps faster while the AI is working.
    var isBusy: Bool = false

    @State private var clock = AsciiClock()
    @State private var onScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animating = onScreen && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { tl in
            Canvas { ctx, size in
                let t = animating ? clock.advance(tl.date, busy: isBusy) : clock.hold()
                AxolotlRenderer.draw(&ctx, size: size, diameter: diameter, t: t)
            }
        }
        .frame(width: diameter * 1.3, height: diameter * 1.15)
        .background(WindowVisibilityReader(isVisible: $onScreen))
        .onDisappear { onScreen = false }
        .accessibilityHidden(true)
    }
}

enum AxolotlRenderer {
    static let colors: [NSColor] = [
        NSColor(red: 0.96, green: 0.95, blue: 0.90, alpha: 1), // cream body
        NSColor(red: 0.95, green: 0.68, blue: 0.75, alpha: 1), // pink gills
    ]

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

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, diameter: CGFloat, t: Float) {
        let ramp = MoonRenderer.ramp
        // Finer glyphs than the moon's (diameter / 17) so the eyes and smile survive sampling.
        let fs = max(5, diameter / 24)
        let cw = fs * 0.62, ch = fs * 1.12
        let atlas = colors.map { color in ramp.map { ctx.resolve(Image(nsImage: MoonRenderer.glyph($0, size: fs, color: color))) } }
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
                let glyph = min(ramp.count - 1, Int(lit * Float(ramp.count)))
                ctx.opacity = Double(0.35 + 0.65 * lit)
                let x = (CGFloat(c) + 0.5) * cw, y = (CGFloat(r) + 0.5) * ch + (gill ? bob * 1.3 : bob)
                ctx.draw(atlas[gill ? 1 : 0][glyph], at: CGPoint(x: x, y: y), anchor: .center)
            }
        }
    }
}
