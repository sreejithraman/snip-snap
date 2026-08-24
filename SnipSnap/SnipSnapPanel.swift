import AppKit

@MainActor
final class SnipSnapPanel: NSPanel {
    static func make(contentViewController: NSViewController) -> SnipSnapPanel {
        let panel = SnipSnapPanel(
            contentRect: NSRect(origin: .zero, size: AppWindowDefaults.defaultSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "Snip Snap"
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.isExcludedFromWindowsMenu = true
        panel.minSize = AppWindowDefaults.minimumSize
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false

        panel.contentViewController = contentViewController
        return panel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
