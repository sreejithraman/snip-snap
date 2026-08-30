import SwiftUI

/// Color roles shared by the Mac and iOS app chrome.
///
/// Platform views own their layout, but both apps read these roles so controls
/// keep the same monochrome Snip Snap look in light and dark mode.
enum SnipSnapTheme {
    static let controlTint = Color.primary
    static let selectionFill = Color.primary.opacity(0.10)
    static let compactSelectionFill = Color.primary.opacity(0.18)
    static let standaloneActionFill = Color.primary.opacity(0.08)
    static let glassEdge = Color.primary.opacity(0.10)
    static let emphasizedGlassEdge = Color.primary.opacity(0.20)
    static let focusedGlassEdge = Color.primary.opacity(0.32)

    static func primaryActionTint(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .black
    }

    static func primaryActionLabel(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .black : .white
    }

    static func disabledPrimaryActionTint(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.14)
    }

    static func disabledPrimaryActionLabel(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.60) : .black.opacity(0.60)
    }
}
