// Luna — Settings › Appearance › Wallpaper.
import SwiftUI
import AppKit
import WebKit
import Combine

struct WallpaperSettingsSection: View {
    /// Onboarding: palette-gradient tiles instead of rendered snapshots, so no web view is created.
    var staticPreviews = false
    @ObservedObject private var store = WallpaperStore.shared
    @StateObject private var thumbnails = WallpaperThumbnails()

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 132), spacing: 12)]

    var body: some View {
        Section {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(WallpaperPreset.allCases) { preset in
                    WallpaperTile(preset: preset,
                                  image: staticPreviews ? nil : thumbnails.images[preset],
                                  gradient: staticPreviews ? gradientColors(for: preset) : nil,
                                  isSelected: store.preset == preset) {
                        store.preset = preset
                    }
                }
            }
            .padding(.vertical, 4)
            .background(alignment: .topLeading) { if !staticPreviews { thumbnails.host } }

            Picker(selection: $store.moonStyle) {
                ForEach(MoonStyle.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Moon style")
                Text("Shader draws a softly lit moon with the GPU.")
            }

            if store.preset != .none {
                styleControls(for: store.preset)
            }
        } header: {
            Text("Wallpaper")
        } footer: {
            if store.preset != .none {
                Text("Wallpapers draw only while a start page is on screen, and hold still with Reduce Motion or Low Power Mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { if !staticPreviews { thumbnails.render(store: store) } }
        .onChange(of: store.styles) { _, _ in if !staticPreviews { thumbnails.render(store: store) } }
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

        LabeledContent("Palette") {
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
        LabeledContent("Accent") {
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

        Toggle(isOn: $store.showMoon) {
            Text("Show moon on top")
            Text("Keep the moon above the greeting while a wallpaper is on.")
        }
        Picker("Frame rate", selection: $store.frameRate) {
            Text("30 fps").tag(30)
            Text("60 fps").tag(60)
        }
        Button("Reset \(preset.title)") { store.resetStyle(for: preset) }
            .disabled(store.style(for: preset) == preset.defaultStyle)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           label: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
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
    let image: NSImage?
    var gradient: [Color]? = nil
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
                    } else if let gradient {
                        LinearGradient(colors: gradient, startPoint: .bottomLeading, endPoint: .topTrailing)
                    } else if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ProgressView().controlSize(.small)
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

/// Renders still thumbnails of each preset in one small, hidden web view.
@MainActor
final class WallpaperThumbnails: ObservableObject {
    @Published private(set) var images: [WallpaperPreset: NSImage] = [:]
    private var rendered: [WallpaperPreset: WallpaperRenderConfig] = [:]
    private let bridge = WallpaperBridge()
    private lazy var webView: WKWebView = {
        let view = WallpaperWeb.makeWebView(bridge: bridge)
        bridge.webView = view
        return view
    }()
    private var loaded = false
    private var pending: WallpaperStore?
    private var running = false

    /// Sits in the window (rendering needs a live layer) but is too small to see.
    var host: some View {
        ThumbnailHost(webView: webView).frame(width: 2, height: 2).opacity(0.02).allowsHitTesting(false)
    }

    init() {
        bridge.onState = { [weak self] state in
            guard state == "loaded", let self else { return }
            self.loaded = true
            if let store = self.pending { self.render(store: store) }
        }
    }

    func render(store: WallpaperStore) {
        _ = webView
        pending = store
        guard loaded, !running else { return }
        running = true
        Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let store = pending {
            pending = nil
            for preset in WallpaperPreset.allCases where preset != .none {
                let config = store.renderConfig(for: preset, still: true)
                guard rendered[preset] != config else { continue }
                if let image = await snapshot(config) {
                    images[preset] = image
                    rendered[preset] = config
                }
            }
        }
        running = false
    }

    private func snapshot(_ config: WallpaperRenderConfig) async -> NSImage? {
        let script = "return await window.lunaWallpaper.snapshot(\(config.json()), 192, 120)"
        guard let result = try? await webView.callAsyncJavaScript(script, contentWorld: .page),
              let url = result as? String,
              let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
}

private struct ThumbnailHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.frame = NSRect(x: 0, y: 0, width: 192, height: 120)
        container.addSubview(webView)
        return container
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
