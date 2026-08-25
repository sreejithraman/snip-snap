import AppKit
import Combine
import SwiftUI

enum PanelFileDropValidation {
    static func existingFiles(in urls: [URL]) -> [URL] {
        urls.filter { url in
            guard url.isFileURL else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ) && !isDirectory.boolValue
        }
    }

    static func newFiles(in urls: [URL], excluding existing: [URL]) -> [URL] {
        var seen = Set(existing)
        let uniqueNewURLs = urls.filter { seen.insert($0).inserted }
        return existingFiles(in: uniqueNewURLs)
    }
}

@MainActor
final class PanelFileDropController: ObservableObject {
    @Published private(set) var isTargeted = false
    let fileDrops = PassthroughSubject<[URL], Never>()

    fileprivate var regionFrameInWindow: NSRect?

    fileprivate func updateRegionFrame(_ frame: NSRect?) {
        regionFrameInWindow = frame
    }

    fileprivate func updateTargeted(_ targeted: Bool) {
        isTargeted = targeted
    }

    func receive(_ urls: [URL]) {
        fileDrops.send(urls)
    }
}

struct PanelFileDropRegion: NSViewRepresentable {
    let controller: PanelFileDropController
    let isEnabled: Bool

    func makeNSView(context: Context) -> NSView {
        PanelFileDropRegionView(controller: controller, isEnabled: isEnabled)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PanelFileDropRegionView)?.setEnabled(isEnabled)
        nsView.needsLayout = true
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? PanelFileDropRegionView)?.setEnabled(false)
    }
}

@MainActor
private final class PanelFileDropRegionView: NSView {
    private let controller: PanelFileDropController
    private var isEnabled: Bool

    init(controller: PanelFileDropController, isEnabled: Bool) {
        self.controller = controller
        self.isEnabled = isEnabled
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateControllerFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateControllerFrame()
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setEnabled(_ isEnabled: Bool) {
        guard self.isEnabled != isEnabled else { return }
        self.isEnabled = isEnabled
        updateControllerFrame()
        if !isEnabled {
            controller.updateTargeted(false)
        }
    }

    private func updateControllerFrame() {
        controller.updateRegionFrame(
            isEnabled && window != nil ? convert(bounds, to: nil) : nil
        )
    }
}

@MainActor
final class PanelFileDropHostingView<Content: View>: NSHostingView<Content> {
    private let controller: PanelFileDropController
    private var validatedDrop: (changeCount: Int, urls: [URL])?

    init(
        rootView: Content,
        controller: PanelFileDropController,
        clipDragSourceController: ClipDragSourceController
    ) {
        self.controller = controller
        super.init(rootView: rootView)
        sizingOptions = []
        registerForDraggedTypes([.fileURL])
        clipDragSourceController.attach(to: self)
    }

    @available(*, unavailable, message: "Use init(rootView:controller:)")
    required init(rootView: Content) {
        fatalError("Use init(rootView:controller:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragState(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDragState(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        validatedDrop = nil
        controller.updateTargeted(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        accepts(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard accepts(sender) else { return false }
        let urls = validFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        controller.updateTargeted(false)
        validatedDrop = nil
        controller.receive(urls)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        validatedDrop = nil
        controller.updateTargeted(false)
    }

    private func updateDragState(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = accepts(sender)
        controller.updateTargeted(accepted)
        return accepted ? .copy : []
    }

    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        guard !(sender.draggingSource is ClipDragSourceController) else {
            return false
        }
        guard sender.draggingPasteboard.types?.contains(ClipDragExportPackage.privateType) != true else {
            return false
        }
        guard let frame = controller.regionFrameInWindow,
              frame.contains(sender.draggingLocation) else {
            return false
        }
        return !validFileURLs(from: sender.draggingPasteboard).isEmpty
    }

    private func validFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let validatedDrop, validatedDrop.changeCount == pasteboard.changeCount {
            return validatedDrop.urls
        }
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        let urls = objects.compactMap { object -> URL? in
            guard let url = object as? NSURL else { return nil }
            return url as URL
        }
        let validURLs = PanelFileDropValidation.existingFiles(in: urls)
        validatedDrop = (pasteboard.changeCount, validURLs)
        return validURLs
    }
}
