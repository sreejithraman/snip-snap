import SnipSnapCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// List identity is shared; native controls still own their size and behavior.
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

    var title: String {
        preset?.title ?? String(localized: "Neutral")
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

    var controlTint: Color {
        preset == nil ? SnipSnapTheme.controlTint : color
    }

    func filledControlLabel(in environment: EnvironmentValues) -> Color {
        let tint = controlTint.resolve(in: environment)
        let luminance = 0.2126 * tint.linearRed + 0.7152 * tint.linearGreen + 0.0722 * tint.linearBlue
        // This threshold chooses the higher-contrast black or white label.
        return luminance > 0.179 ? .black : .white
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
    var accent: SnipListAppearance { SnipListAppearance(preset: color) }

    /// Keep a visible identity on older devices without changing the saved choice.
    var displaySystemImage: String { ListIconSymbol.supportedName(systemImage) }
}

enum ListIconSymbol {
    static func supportedName(_ name: String) -> String {
#if os(macOS)
        let isAvailable = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
#else
        let isAvailable = UIImage(systemName: name) != nil
#endif
        return isAvailable ? name : "list.bullet"
    }
}

struct SnipListColorPicker: View {
    @Binding var selection: SnipListColorPreset?
    var showsTitle = true
    private static let options = [nil] + SnipListColorPreset.allCases.map(Optional.some)

    private var columns: [GridItem] {
        return Array(repeating: GridItem(.flexible(minimum: 44), spacing: SnipSnapSpacing.cardContentInset), count: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            if showsTitle {
                Text("Color").font(.subheadline.weight(.semibold))
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
                                color: SnipListAppearance(preset: preset).color,
                                isSelected: selected,
                                diameter: 32
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset?.title ?? String(localized: "Neutral"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("list-color-\(preset?.rawValue ?? "neutral")")
                        .help(preset?.title ?? String(localized: "Neutral"))
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("List color")
        }
    }
}

/// A tinted glass circle marks selection while keeping the swatch's color visible.
struct SnipListColorSwatch: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let color: Color
    let isSelected: Bool
    var diameter: CGFloat = 32

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Circle().fill(color)
                    .frame(width: diameter, height: diameter)
            } else {
                Circle()
                    .fill(.clear)
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

/// The same circular selection treatment for list icons and colors.
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
