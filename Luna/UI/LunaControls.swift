// Luna's own pop-up and segmented pickers. With Liquid Glass on they are the
// native SwiftUI pickers (unchanged look); with it off they draw solid controls
// and open a Luna menu, so no system glass shows.
import SwiftUI
import AppKit

struct LunaPickerOption<Value: Hashable> {
    var value: Value
    var title: String
    var image: NSImage? = nil

    init(_ value: Value, _ title: String, image: NSImage? = nil) {
        self.value = value
        self.title = title
        self.image = image
    }
}

/// The closed state of a Luna pop-up: current value and a chevron, on a solid raised fill.
struct LunaPopUpLabel: View {
    let title: String
    var image: NSImage? = nil
    var isOpen = false

    var body: some View {
        HStack(spacing: 6) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 14, height: 14)
            }
            Text(title).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5))
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .frame(height: 23)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isOpen ? LunaSurface.pressed : LunaSurface.raised))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(LunaSurface.stroke))
        .shadow(color: .black.opacity(0.06), radius: 0.5, y: 0.5)
        .contentShape(Rectangle())
    }
}

/// A pop-up picker (Form row: label left, value right).
struct LunaPicker<Value: Hashable>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var selection: Value
    let options: [LunaPickerOption<Value>]
    private var glass: Bool { ThemeStore.shared.glass.isOn(.menus) }

    init(_ title: String, subtitle: String? = nil, selection: Binding<Value>, options: [LunaPickerOption<Value>]) {
        self.title = title
        self.subtitle = subtitle
        self._selection = selection
        self.options = options
    }

    var body: some View {
        if glass {
            Picker(selection: $selection) {
                ForEach(options.indices, id: \.self) { i in
                    if let image = options[i].image {
                        Label { Text(options[i].title) } icon: { Image(nsImage: image) }.tag(options[i].value)
                    } else {
                        Text(options[i].title).tag(options[i].value)
                    }
                }
            } label: { label }
        } else {
            LabeledContent { menu } label: { label }
        }
    }

    @ViewBuilder private var label: some View {
        Text(title)
        if let subtitle { Text(subtitle) }
    }

    private var menu: some View {
        let current = options.first { $0.value == selection }
        return LunaMenuButton(minWidth: 160, items: {
            options.enumerated().map { i, option in
                .item(LunaMenuItem(id: "opt.\(i)", title: option.title, icon: option.image.map { .image($0) },
                                   isChecked: option.value == selection, action: { selection = option.value }))
            }
        }) { isOpen in
            LunaPopUpLabel(title: current?.title ?? "", image: current?.image, isOpen: isOpen)
        }
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(current?.title ?? "")
    }
}

/// A segmented picker.
struct LunaSegmentedPicker<Value: Hashable>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var selection: Value
    let options: [LunaPickerOption<Value>]
    private var glass: Bool { ThemeStore.shared.glass.isOn(.menus) }

    init(_ title: String, subtitle: String? = nil, selection: Binding<Value>, options: [LunaPickerOption<Value>]) {
        self.title = title
        self.subtitle = subtitle
        self._selection = selection
        self.options = options
    }

    var body: some View {
        if glass {
            Picker(selection: $selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].title).tag(options[i].value) }
            } label: { label }
            .pickerStyle(.segmented)
        } else {
            LabeledContent { segments } label: { label }
        }
    }

    @ViewBuilder private var label: some View {
        Text(title)
        if let subtitle { Text(subtitle) }
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Segment(title: options[i].title, isSelected: options[i].value == selection) {
                    selection = options[i].value
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LunaSurface.hover))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(LunaSurface.stroke))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private struct Segment: View {
        let title: String
        let isSelected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 28, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? LunaSurface.raised : (hovering ? LunaSurface.hover : .clear))
                        .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
    }
}
