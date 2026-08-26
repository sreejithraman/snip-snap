import AppKit

enum AppWindowDefaults {
    static let effectGutter: CGFloat = 24
    static let defaultContentSize = CGSize(width: 382, height: 452)
    static let minimumContentSize = CGSize(width: 340, height: 420)
    static let defaultSize = windowSize(for: defaultContentSize)
    static let minimumSize = windowSize(for: minimumContentSize)
    // TODO: Rename after the 1.0 migration window.
    // Keep the original key so upgrades retain the saved window frame.
    static let frameAutosaveName = NSWindow.FrameAutosaveName("InboxPanel")

    static func windowSize(for contentSize: CGSize) -> CGSize {
        CGSize(
            width: contentSize.width + effectGutter * 2,
            height: contentSize.height + effectGutter * 2
        )
    }
}
