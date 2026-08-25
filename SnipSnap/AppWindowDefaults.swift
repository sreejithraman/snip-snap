import AppKit

enum AppWindowDefaults {
    static let effectGutter: CGFloat = 24
    static let defaultContentSize = CGSize(width: 382, height: 652)
    static let minimumContentSize = CGSize(width: 340, height: 420)
    static let defaultSize = windowSize(for: defaultContentSize)
    static let minimumSize = windowSize(for: minimumContentSize)
    static let frameAutosaveName = NSWindow.FrameAutosaveName("InboxPanel")

    static func windowSize(for contentSize: CGSize) -> CGSize {
        CGSize(
            width: contentSize.width + effectGutter * 2,
            height: contentSize.height + effectGutter * 2
        )
    }
}
