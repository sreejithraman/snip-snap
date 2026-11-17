import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// App-owned text uses Allo. Code and attributed user content keep their own fonts.
enum AppTypography {
    enum Weight: String {
        case regular = "Regular"
        case medium = "Medium"
        case semibold = "SemiBold"
        case bold = "Bold"

        var systemWeight: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    private static let registered: Bool = {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts/Allo"),
              !urls.isEmpty else { return false }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return CTFontCopyFamilyName(CTFontCreateWithName("Allo-Regular" as CFString, 0, nil)) as String == "Allo"
    }()

    static func font(_ style: Font.TextStyle, weight: Weight? = nil, in context: Font.Context) -> Font {
        Font(applyingFeatures(to: semanticFont(style, weight: weight).resolve(in: context).ctFont))
    }

    static var markdownHeadingFont: Font { semanticFont(.body, weight: .semibold) }

    static func attributedText(_ text: AttributedString, in context: Font.Context) -> AttributedString {
        var result = text
        for run in text.runs {
            guard let font = run.font else { continue }
            let resolved = font.resolve(in: context).ctFont
            if CTFontCopyFamilyName(resolved) as String == "Allo" {
                result[run.range].font = Font(applyingFeatures(to: resolved))
            }
        }
        return result
    }

    private static func semanticFont(_ style: Font.TextStyle, weight: Weight? = nil) -> Font {
        let weight = weight ?? defaultWeight(for: style)
        guard registered else { return .system(style, weight: weight.systemWeight) }
        return .custom(name(for: weight), size: baseSize(for: style), relativeTo: style)
    }

    static func font(size: CGFloat, weight: Weight = .regular) -> Font {
        guard registered else { return .system(size: size, weight: weight.systemWeight) }
        return Font(nativeFont(size: size, weight: weight))
    }

    private static func defaultWeight(for style: Font.TextStyle) -> Weight {
#if os(macOS)
        style == .headline ? .bold : .regular
#else
        style == .headline ? .semibold : .regular
#endif
    }

    private static func name(for weight: Weight) -> String {
        "Allo-\(weight.rawValue)"
    }

    // Keep literal text literal: calt substitutes arrows, and frac substitutes fractions.
    private static let features = [
        ("ss01", 1), ("ss02", 1), ("ss03", 0), ("calt", 0), ("frac", 0)
    ]

    private static func applyingFeatures(to font: CTFont) -> CTFont {
        guard CTFontCopyFamilyName(font) as String == "Allo" else { return font }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFeatureSettingsAttribute: features.map {
                [kCTFontOpenTypeFeatureTag: $0.0, kCTFontOpenTypeFeatureValue: $0.1]
            }
        ] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, descriptor)
    }

    private static func coreTextFont(size: CGFloat, weight: Weight) -> CTFont {
        applyingFeatures(to: CTFontCreateWithName(name(for: weight) as CFString, size, nil))
    }

    private static func baseSize(for style: Font.TextStyle) -> CGFloat {
#if os(macOS)
        let native: NSFont.TextStyle = switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
        return NSFont.preferredFont(forTextStyle: native).pointSize
#else
        return UIFont.preferredFont(
            forTextStyle: nativeStyle(for: style),
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
#endif
    }

#if os(macOS)
    static func nativeFont(size: CGFloat, weight: Weight = .regular) -> NSFont {
        guard registered else {
            return .systemFont(ofSize: size)
        }
        return coreTextFont(size: size, weight: weight) as NSFont
    }
#else
    private static func nativeStyle(for style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }

    static func nativeFont(size: CGFloat, weight: Weight = .regular) -> UIFont {
        guard registered else {
            return .systemFont(ofSize: size)
        }
        return coreTextFont(size: size, weight: weight) as UIFont
    }

    static func preferredFont(
        _ style: Font.TextStyle, weight: Weight? = nil, compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        UIFontMetrics(forTextStyle: nativeStyle(for: style)).scaledFont(
            for: nativeFont(size: baseSize(for: style), weight: weight ?? defaultWeight(for: style)),
            compatibleWith: traits
        )
    }

    @MainActor
    static func configureNavigationBar() {
        UINavigationBar.appearance().titleTextAttributes = [.font: preferredFont(.headline)]
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: preferredFont(.largeTitle, weight: .bold)]
        for state: UIControl.State in [.normal, .highlighted, .disabled, .focused] {
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: preferredFont(.body)], for: state)
        }
    }
#endif
}

private struct AppFontModifier: ViewModifier {
    let style: Font.TextStyle
    let weight: AppTypography.Weight?
    @Environment(\.fontResolutionContext) private var context

    func body(content: Content) -> some View {
        content.font(AppTypography.font(style, weight: weight, in: context))
    }
}

extension View {
    func appFont(_ style: Font.TextStyle, weight: AppTypography.Weight? = nil) -> some View {
        modifier(AppFontModifier(style: style, weight: weight))
    }
}
