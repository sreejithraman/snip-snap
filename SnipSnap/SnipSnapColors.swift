import AppKit
import SwiftUI

/// The app's semantic color roles. Views choose a role; this type owns the
/// visible color and opacity needed to express it.
enum SnipSnapColors {
    // MARK: Text

    static let textPrimary = AnyShapeStyle(HierarchicalShapeStyle.primary)
    static let textSecondary = AnyShapeStyle(HierarchicalShapeStyle.secondary)
    static let textTertiary = AnyShapeStyle(HierarchicalShapeStyle.tertiary)
    static let textError = AnyShapeStyle(Color(nsColor: .systemRed))
    static let doneStrikethrough = Color.secondary

    // MARK: Controls and interaction

    static let controlTint = Color.primary
    static let selectionFill = Color.primary.opacity(0.10)
    static let selectionEdge = Color.primary.opacity(0.50)
    static let compactSelectionFill = Color.primary.opacity(0.18)
    static let compactSubduedFill = Color.primary.opacity(0.05)
    static let dropTargetFill = Color.primary.opacity(0.08)
    static let dropTargetEdge = Color.primary.opacity(0.48)
    static let insertionEdge = Color.primary.opacity(0.20)

    static func developmentBadge(tone: DevelopmentBadgeTone) -> Color {
        switch tone {
        case .red: Color(nsColor: .systemRed)
        case .orange: Color(nsColor: .systemOrange)
        case .yellow: Color(nsColor: .systemYellow)
        case .green: Color(nsColor: .systemGreen)
        case .blue: Color(nsColor: .systemBlue)
        case .indigo: Color(nsColor: .systemIndigo)
        case .violet: Color(nsColor: .systemPurple)
        case .black: .black
        case .white: .white
        }
    }

    static func developmentBadgeLabel(
        tone: DevelopmentBadgeTone,
        colorScheme: ColorScheme
    ) -> Color {
        tone.usesDarkLabel(in: colorScheme) ? .black : .white
    }

    static func developmentBadgeEdge(tone: DevelopmentBadgeTone) -> Color {
        tone == .white ? .black.opacity(0.30) : .white.opacity(0.75)
    }

    static func primaryActionTint(for colorScheme: ColorScheme) -> Color {
        // Send needs exact monochrome contrast; the hierarchical primary color
        // is softer than black and white on macOS.
        colorScheme == .dark ? .white : .black
    }

    static func primaryActionLabel(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .black : .white
    }

    // MARK: Surfaces

    static let standaloneActionFill = Color.primary.opacity(0.08)
    static let glassEdge = Color.primary.opacity(0.10)
    static let emphasizedGlassEdge = Color.primary.opacity(0.20)
    static let focusedGlassEdge = Color.primary.opacity(0.32)
    static let attachmentFill = Color.primary.opacity(0.055)
    static let attachmentEdge = Color.primary.opacity(0.12)
    static let contentCardEdge = Color(nsColor: .separatorColor)

    static func contentCardShadow(isSelected: Bool) -> Color {
        Color.black.opacity(isSelected ? 0.14 : 0.10)
    }

    // MARK: State strength

    static let doneTextOpacity = 0.65
    static let doneCardOpacity = 0.55

    // MARK: Generated document previews

    // These are document pixels rather than app chrome. Fixed paper and ink
    // keep a generated text-file thumbnail stable in either app theme.
    static let documentPreviewPaper = NSColor(calibratedWhite: 0.98, alpha: 1)
    static let documentPreviewInk = NSColor(calibratedWhite: 0.12, alpha: 1)
}
