import AppKit
import SwiftUI

@MainActor
struct PanelCardContextMenu {
    let makeMenu: () -> NSMenu
    let onOpen: () -> Void
    let onClose: () -> Void
}

@MainActor
final class PanelCardInteractionController: NSObject, ObservableObject, NSGestureRecognizerDelegate {
    private final class Region {
        weak var view: NSView?

        init(view: NSView) {
            self.view = view
        }
    }

    private weak var hostView: NSView?
    private var regions: [UUID: Region] = [:]
    private var onClickAway: () -> Void = {}

    private lazy var primaryClickRecognizer: NSClickGestureRecognizer = {
        let recognizer = NSClickGestureRecognizer(
            target: self,
            action: #selector(handlePrimaryClick(_:))
        )
        recognizer.buttonMask = 0x1
        recognizer.delaysPrimaryMouseButtonEvents = false
        recognizer.delegate = self
        return recognizer
    }()

    func attach(to hostView: NSView?) {
        guard self.hostView !== hostView else { return }
        if let current = self.hostView {
            current.removeGestureRecognizer(primaryClickRecognizer)
        }
        self.hostView = hostView
        guard let hostView else { return }
        hostView.addGestureRecognizer(primaryClickRecognizer)
    }

    func configure(onClickAway: @escaping () -> Void) {
        self.onClickAway = onClickAway
    }

    func updateRegion(
        id: UUID,
        view: NSView?
    ) {
        guard let view, view.window != nil else {
            regions.removeValue(forKey: id)
            return
        }
        regions[id] = Region(view: view)
    }

    func removeRegion(id: UUID) {
        regions.removeValue(forKey: id)
    }

    func regionID(atWindowPoint point: NSPoint) -> UUID? {
        region(atWindowPoint: point)?.key
    }

    func clearSelectionIfClickAway(atWindowPoint point: NSPoint) {
        guard region(atWindowPoint: point) == nil else { return }
        onClickAway()
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        Self.isPrimaryClick(event: event)
    }

    static func isContextClick(
        buttonNumber: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        buttonNumber == 1 || (buttonNumber == 0 && modifiers.contains(.control))
    }

    static func isContextClick(event: NSEvent) -> Bool {
        guard event.type == .rightMouseDown || event.type == .leftMouseDown else {
            return false
        }
        return isContextClick(
            buttonNumber: event.buttonNumber,
            modifiers: event.modifierFlags
        )
    }

    static func isPrimaryClick(
        buttonNumber: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        buttonNumber == 0 && !modifiers.contains(.control)
    }

    static func isPrimaryClick(event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else { return false }
        return isPrimaryClick(
            buttonNumber: event.buttonNumber,
            modifiers: event.modifierFlags
        )
    }

    @objc
    private func handlePrimaryClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended,
              let hostView else { return }
        let point = hostView.convert(recognizer.location(in: hostView), to: nil)
        clearSelectionIfClickAway(atWindowPoint: point)
    }

    private func region(atWindowPoint point: NSPoint) -> Dictionary<UUID, Region>.Element? {
        regions = regions.filter { $0.value.view?.window != nil }
        return regions.first { _, region in
            guard let view = region.view else { return false }
            return Self.visibleFrameInWindow(for: view).contains(point)
        }
    }

    static func visibleFrameInWindow(for view: NSView) -> NSRect {
        var frame = view.convert(view.bounds, to: nil)
        var ancestor = view.superview
        while let current = ancestor, !frame.isNull {
            frame = frame.intersection(current.convert(current.bounds, to: nil))
            ancestor = current.superview
        }
        return frame
    }
}

struct PanelCardInteractionHost: NSViewRepresentable {
    let controller: PanelCardInteractionController
    let onClickAway: () -> Void

    func makeNSView(context: Context) -> PanelCardInteractionHostView {
        PanelCardInteractionHostView(
            controller: controller,
            onClickAway: onClickAway
        )
    }

    func updateNSView(_ nsView: PanelCardInteractionHostView, context: Context) {
        nsView.configure(onClickAway: onClickAway)
    }

    static func dismantleNSView(_ nsView: PanelCardInteractionHostView, coordinator: ()) {
        nsView.detach()
    }
}

@MainActor
final class PanelCardInteractionHostView: NSView {
    private let controller: PanelCardInteractionController

    init(
        controller: PanelCardInteractionController,
        onClickAway: @escaping () -> Void
    ) {
        self.controller = controller
        super.init(frame: .zero)
        configure(onClickAway: onClickAway)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller.attach(to: window?.contentView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(onClickAway: @escaping () -> Void) {
        controller.configure(onClickAway: onClickAway)
    }

    func detach() {
        controller.attach(to: nil)
    }
}

struct PanelCardInteractionRegion: NSViewRepresentable {
    let controller: PanelCardInteractionController
    let id: UUID
    let contextMenu: PanelCardContextMenu

    func makeNSView(context: Context) -> PanelCardInteractionRegionView {
        PanelCardInteractionRegionView(
            controller: controller,
            id: id,
            contextMenu: contextMenu
        )
    }

    func updateNSView(_ nsView: PanelCardInteractionRegionView, context: Context) {
        nsView.configure(contextMenu: contextMenu)
    }

    static func dismantleNSView(_ nsView: PanelCardInteractionRegionView, coordinator: ()) {
        nsView.removeFromController()
    }
}

@MainActor
final class PanelCardInteractionRegionView: NSView {
    private let controller: PanelCardInteractionController
    private let id: UUID
    private var contextMenu: PanelCardContextMenu

    init(
        controller: PanelCardInteractionController,
        id: UUID,
        contextMenu: PanelCardContextMenu
    ) {
        self.controller = controller
        self.id = id
        self.contextMenu = contextMenu
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(contextMenu: PanelCardContextMenu) {
        self.contextMenu = contextMenu
        updateController()
    }

    override func layout() {
        super.layout()
        updateController()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateController()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil,
              let event = NSApp.currentEvent,
              PanelCardInteractionController.isContextClick(event: event) else { return nil }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard PanelCardInteractionController.isContextClick(event: event) else {
            super.mouseDown(with: event)
            return
        }
        showContextMenu(for: event)
    }

    func removeFromController() {
        controller.removeRegion(id: id)
    }

    private func showContextMenu(for event: NSEvent) {
        let menu = contextMenu.makeMenu()
        guard !menu.items.isEmpty else { return }
        contextMenu.onOpen()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        contextMenu.onClose()
    }

    private func updateController() {
        controller.updateRegion(
            id: id,
            view: window == nil ? nil : self
        )
    }
}

@MainActor
final class PanelContextMenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(
        title: String,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) {
        self.handler = handler
        super.init(
            title: title,
            action: #selector(performHandler),
            keyEquivalent: ""
        )
        target = self
        self.isEnabled = isEnabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performHandler() {
        handler()
    }
}

@MainActor
extension NSMenu {
    func addPanelAction(
        _ title: String,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) {
        autoenablesItems = false
        addItem(
            PanelContextMenuActionItem(
                title: title,
                isEnabled: isEnabled,
                handler: handler
            )
        )
    }

    func addPanelSubmenu(_ title: String, build: (NSMenu) -> Void) {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        build(submenu)

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
