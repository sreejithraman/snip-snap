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

    func sendIconColor(in colorScheme: ColorScheme) -> Color {
        preset == nil
            ? (colorScheme == .dark ? .black : .white)
            : SnipSnapTheme.sendIconColor(tint: color)
    }

}

extension SnipList {
    var accent: SnipListAppearance { SnipListAppearance(preset: color) }
}

struct SnipListColorPicker: View {
    @Binding var selection: SnipListColorPreset?
    private static let options = [nil] + SnipListColorPreset.allCases.map(Optional.some)

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            Text("Color").font(.subheadline.weight(.semibold))
            GlassEffectContainer(spacing: SnipSnapSpacing.relatedContent) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: SnipSnapSpacing.cardContentInset), count: 4),
                    spacing: SnipSnapSpacing.paneContentInset
                ) {
                    ForEach(Self.options, id: \.self) { preset in
                        let selected = selection == preset
                        Button {
                            selection = preset
                        } label: {
                            SnipListColorSwatch(
                                color: SnipListAppearance(preset: preset).color,
                                isSelected: selected
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
        }
    }
}

/// A tinted glass circle marks selection while keeping the swatch's color visible.
struct SnipListColorSwatch: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let color: Color
    let isSelected: Bool
    private let diameter: CGFloat = 32

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
                    Group {
                        if reduceTransparency || contrast == .increased {
                            Circle().strokeBorder(Color.primary, lineWidth: 2)
                        } else {
                            // Keep the selection lens separate from the colored glass below it.
                            GlassEffectContainer {
                                Color.clear
                                    .frame(width: diameter + 12, height: diameter + 12)
                                    .glassEffect(.regular.tint(SnipSnapTheme.listSelectionGlassTint), in: Circle())
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}
