import SnipSnapCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension SnipListColorPreset {

    var title: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .teal: String(localized: "Teal")
        case .blue: String(localized: "Blue")
        case .indigo: String(localized: "Indigo")
        case .violet: String(localized: "Violet")
        case .pink: String(localized: "Pink")
        case .clay: String(localized: "Clay")
        case .slate: String(localized: "Slate")
        }
    }

}

struct SnipListAppearance {
    let preset: SnipListColorPreset?
    private static let blackWhiteLabelContrastThreshold: Float = 0.179

    var title: String {
        preset?.title ?? String(localized: "Automatic")
    }

    private static func components(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        let value = UInt32(hex.dropFirst(), radix: 16)!
        return (CGFloat((value >> 16) & 255) / 255,
                CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255)
    }

    var color: Color {
        guard let pair = preset?.color else { return .primary }
#if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (r, g, b) = Self.components(dark ? pair.dark : pair.light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
#else
        return Color(uiColor: UIColor { traits in
            let (r, g, b) = Self.components(traits.userInterfaceStyle == .dark ? pair.dark : pair.light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
#endif
    }

    var selectionFill: Color { color.opacity(0.16) }

    var badgeFill: Color { preset == nil ? Color.secondary.opacity(0.3) : color }

    func badgeLabel(in environment: EnvironmentValues) -> Color {
        preset == nil ? .primary : filledControlLabel(in: environment)
    }

    var controlTint: Color {
        preset == nil ? SnipSnapTheme.controlTint : color
    }

    func filledControlLabel(in environment: EnvironmentValues) -> Color {
        let tint = controlTint.resolve(in: environment)
        let luminance = 0.2126 * tint.linearRed + 0.7152 * tint.linearGreen + 0.0722 * tint.linearBlue
        return luminance > Self.blackWhiteLabelContrastThreshold ? .black : .white
    }

    func sendIconColor(in colorScheme: ColorScheme) -> Color {
        preset == nil
            ? (colorScheme == .dark ? .black : .white)
            : SnipSnapTheme.sendIconColor(tint: color)
    }

    func sendColors(
        in colorScheme: ColorScheme,
        chrome: SnipListSendChrome
    ) -> SnipListSendColors {
        let label = sendIconColor(in: colorScheme)
        switch chrome {
        case .prominent:
            return SnipListSendColors(tint: controlTint, label: label)
        case .glass:
            return SnipListSendColors(
                tint: color.opacity(SnipSnapTheme.listGlassTintOpacity),
                label: label
            )
        }
    }

}

enum SnipListSendChrome {
    case prominent
    case glass
}

struct SnipListSendColors {
    var tint: Color
    var label: Color
}

extension SnipList {
    var accent: SnipListAppearance { SnipListAppearance(preset: tint) }

    /// Letters stand in for a symbol this OS can't draw, so older devices keep a visible identity.
    var displayMark: SnipListMark { mark(isAvailable: ListIconSymbol.isAvailable) }
}

enum ListIconSymbol {
    /// What an icon picker shows for its stored choice: the symbol if this OS can draw it, else a letters sample.
    static func pickerMark(for selection: String) -> SnipListMark {
        SnipList.icon(stored: selection).flatMap { isAvailable($0) ? .icon($0) : nil } ?? .letters("Aa")
    }

    static func isAvailable(_ name: String) -> Bool {
#if os(macOS)
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
#else
        UIImage(systemName: name) != nil
#endif
    }
}

/// A list's symbol in its color, or its letters in a circle of its color.
struct SnipListMarkView: View {
    @Environment(\.self) private var environment
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    let mark: SnipListMark
    let appearance: SnipListAppearance
    var diameter: CGFloat = 22
    var scalesWithText = true

    init(mark: SnipListMark, appearance: SnipListAppearance, diameter: CGFloat = 22, scalesWithText: Bool = true) {
        self.mark = mark
        self.appearance = appearance
        self.diameter = diameter
        self.scalesWithText = scalesWithText
    }

    init(list: SnipList, diameter: CGFloat = 22, scalesWithText: Bool = true) {
        self.init(mark: list.displayMark, appearance: list.accent, diameter: diameter, scalesWithText: scalesWithText)
    }

    var body: some View {
        let size = diameter * (scalesWithText ? textScale : 1)
        Group {
            switch mark {
            case .icon(let systemImage):
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.6, weight: .medium))
                    .foregroundStyle(appearance.color)
            case .letters(let letters):
                Text(verbatim: letters)
                    .font(AppTypography.font(size: size * (letters.count > 1 ? 0.42 : 0.52), weight: .semibold))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(appearance.badgeLabel(in: environment))
                    .padding(size * 0.08)
                    .frame(width: size, height: size)
                    .background(appearance.badgeFill, in: Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension SnipList {
    /// Menus draw only images, so letters are rendered to one in this environment's appearance.
    @MainActor
    func menuMarkImage(in environment: EnvironmentValues, diameter: CGFloat = 18) -> Image {
        guard case .letters = displayMark, let image = renderedLetters(in: environment, diameter: diameter) else {
            return Image(systemName: icon ?? "circle.fill")
        }
#if os(macOS)
        return Image(nsImage: image).renderingMode(.original)
#else
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal)).renderingMode(.original)
#endif
    }

#if os(macOS)
    /// For AppKit menus: letters rendered for the panel's color scheme, or the list's symbol.
    @MainActor
    func menuMarkImage(colorScheme: ColorScheme, diameter: CGFloat = 16) -> NSImage? {
        guard case .letters = displayMark else {
            return icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        }
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        environment.displayScale = NSScreen.main?.backingScaleFactor ?? 2
        return renderedLetters(in: environment, diameter: diameter)
    }

    @MainActor
    private func renderedLetters(in environment: EnvironmentValues, diameter: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: letterBadge(in: environment, diameter: diameter))
        renderer.scale = environment.displayScale
        return renderer.nsImage
    }
#else
    @MainActor
    private func renderedLetters(in environment: EnvironmentValues, diameter: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: letterBadge(in: environment, diameter: diameter))
        renderer.scale = environment.displayScale
        return renderer.uiImage
    }
#endif

    @MainActor
    private func letterBadge(in environment: EnvironmentValues, diameter: CGFloat) -> some View {
        SnipListMarkView(list: self, diameter: diameter, scalesWithText: false)
            .environment(\.colorScheme, environment.colorScheme)
    }
}

struct SnipListColorPicker: View {
    @Binding var selection: SnipListColorPreset?
    /// The color a list gets without a choice; nil before the list exists.
    var automatic: SnipListColorPreset?
    var showsTitle = true
    private static let options = [nil] + SnipListColorPreset.allCases.map(Optional.some)

    private var columns: [GridItem] {
        return Array(repeating: GridItem(.flexible(minimum: 44), spacing: SnipSnapSpacing.cardContentInset), count: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            if showsTitle {
                Text("Color").appFont(.subheadline, weight: .semibold)
            }
            GlassEffectContainer(spacing: SnipSnapSpacing.relatedContent) {
                LazyVGrid(
                    columns: columns,
                    spacing: SnipSnapSpacing.paneContentInset
                ) {
                    ForEach(Self.options, id: \.self) { preset in
                        let selected = selection == preset
                        Button {
                            selection = preset
                        } label: {
                            SnipListColorSwatch(
                                color: SnipListAppearance(preset: preset ?? automatic).color,
                                isSelected: selected,
                                diameter: 32,
                                symbol: preset == nil ? "sparkles" : nil
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(SnipListAppearance(preset: preset).title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("list-color-\(preset?.rawValue ?? "automatic")")
                        .help(SnipListAppearance(preset: preset).title)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("List color")
        }
    }
}

/// The icon choice that shows a list's letters instead of a symbol.
struct SnipListNoIconButton: View {
    @Binding var selection: String
    var didSelect: () -> Void = {}

    var body: some View {
        let isSelected = SnipList.icon(stored: selection) == nil
        Button {
            selection = ""
            didSelect()
        } label: {
            HStack(spacing: SnipSnapSpacing.relatedContent) {
                SnipListMarkView(mark: .letters("Aa"), appearance: SnipListAppearance(preset: nil), diameter: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("No icon").appFont(.body, weight: .medium)
                    Text("Show the list’s first letters").appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark").appFont(.body, weight: .semibold)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? SnipSnapTheme.selectionFill : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("No icon")
        .accessibilityHint("Shows the list’s first letters")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("list-icon-none")
    }
}

struct SnipListColorSwatch: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let color: Color
    let isSelected: Bool
    var diameter: CGFloat = 32
    /// A symbol drawn on the swatch, such as the Automatic choice's sparkles.
    var symbol: String?

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Circle().fill(color)
                    .frame(width: diameter, height: diameter)
                    .overlay { symbolImage }
            } else {
                symbolImage
                    .frame(width: diameter, height: diameter)
                    .glassEffect(
                        .regular.tint(color.opacity(SnipSnapTheme.listGlassTintOpacity)).interactive(),
                        in: Circle()
                    )
            }
        }
            .padding(6)
            .overlay {
                if isSelected {
                    SnipListSelectionLens()
                        .frame(width: diameter + 12, height: diameter + 12)
                }
            }
    }
}

extension SnipListColorSwatch {
    @ViewBuilder fileprivate var symbolImage: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}

struct SnipListSelectionLens: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Circle().strokeBorder(Color.primary, lineWidth: 2)
            } else {
                GlassEffectContainer {
                    Color.clear
                        .glassEffect(.regular.tint(SnipSnapTheme.listSelectionGlassTint), in: Circle())
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
