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
        case .neutral: String(localized: "Neutral")
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .green: String(localized: "Green")
        case .yellow: String(localized: "Yellow")
        case .blue: String(localized: "Blue")
        case .violet: String(localized: "Violet")
        case .indigo: String(localized: "Indigo")
        }
    }

}

struct SnipListAppearance {
    let pair: SnipListColor?

    var title: String {
        SnipListColorPreset.allCases.first { $0.color == pair }?.title ?? String(localized: "Custom")
    }

    private static func components(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        let value = UInt32(hex.dropFirst(), radix: 16)!
        return (CGFloat((value >> 16) & 255) / 255,
                CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255)
    }

    var color: Color {
        guard let pair else { return .primary }
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
        pair == nil
            ? (colorScheme == .dark ? .black : .white)
            : SnipSnapTheme.sendIconColor(tint: color)
    }

}

extension SnipList {
    var accent: SnipListAppearance { SnipListAppearance(pair: color) }
}

struct SnipListColorPicker: View {
    @Binding var selection: SnipListColor?

    var body: some View {
        VStack(alignment: .leading, spacing: SnipSnapSpacing.relatedContent) {
            Text("Color").font(.subheadline.weight(.semibold))
            if !SnipListColorPreset.allCases.contains(where: { $0.color == selection }) {
                Label("Custom", systemImage: "circle.fill")
                    .foregroundStyle(SnipListAppearance(pair: selection).color)
            }
            GlassEffectContainer(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: 4), count: 4), spacing: 4) {
                    ForEach(SnipListColorPreset.allCases, id: \.rawValue) { accent in
                        let selected = selection == accent.color
                        Button {
                            selection = accent.color
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .opacity(selected ? 1 : 0)
                                .frame(width: 28, height: 28)
#if os(macOS)
                                .padding(4)
                                .glassEffect(
                                    .regular.tint(
                                        SnipListAppearance(pair: accent.color).color.opacity(SnipSnapTheme.listGlassTintOpacity)
                                    ).interactive(),
                                    in: Circle()
                                )
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
#endif
                        }
#if os(macOS)
                        .buttonStyle(.plain)
#else
                        .buttonStyle(.glass(.regular.tint(
                            SnipListAppearance(pair: accent.color).color.opacity(SnipSnapTheme.listGlassTintOpacity)
                        )))
                        .buttonBorderShape(.circle)
#endif
                        .foregroundStyle(.primary)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(accent.title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("list-color-\(accent.rawValue)")
                        .help(accent.title)
                    }
                }
            }
        }
    }
}
