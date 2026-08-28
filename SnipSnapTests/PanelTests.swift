import XCTest
import AppKit
import SwiftUI
@testable import SnipSnap

// SwiftUI may still resolve Transferable metadata after this test returns.
// Keep its host alive until the short-lived test process exits.
@MainActor
private var processLifetimePanelSearchWindows: [NSWindow] = []

private final class PanelResizeTrackingEvent: NSEvent {
    private let generatingTrackingArea: NSTrackingArea

    override var trackingArea: NSTrackingArea? { generatingTrackingArea }

    init(trackingArea: NSTrackingArea) {
        generatingTrackingArea = trackingArea
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class PanelResizeCancelResponder: NSResponder {
    private(set) var didCancel = false

    override func cancelOperation(_ sender: Any?) {
        didCancel = true
    }
}

@MainActor
private final class PanelTextValue {
    var text: String

    init(_ text: String) {
        self.text = text
    }
}

final class PanelTests: StoreBackedTestCase {
    @MainActor
    func testGlobalSearchUsesOneScrollViewForSavedAndClipboardResults() async throws {
        let clipboardEntry = ClipboardEntry(
            sourceApplication: "Tests",
            items: [
                ClipboardPayloadItem(
                    representations: [
                        ClipboardRepresentation(
                            type: NSPasteboard.PasteboardType.string.rawValue,
                            data: Data("shared search term".utf8)
                        )
                    ]
                )
            ]
        )
        let clipboardURL = try storeURL()
            .deletingLastPathComponent()
            .appendingPathComponent("clipboard.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([clipboardEntry]).write(to: clipboardURL, options: .atomic)

        let pasteboard = NSPasteboard(
            name: .init("world.sree.snipsnap.panel-search-tests.\(UUID().uuidString)")
        )
        let defaultsName = "Snip SnapPanelSearchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let history = ClipboardHistory(
            pasteboard: pasteboard,
            defaults: defaults,
            storeURL: clipboardURL
        )
        await history.waitForInitialLoad()

        let model = AppModel(
            repository: try SnipRepository(fileURL: try storeURL()),
            defaults: defaults,
            clipboardHistory: history
        )
        _ = await model.add(content: "shared search term", origin: .quickEntry)
        model.query = "shared search term"
        let settings = ShortcutSettings(defaults: defaults)
        let rootView = ContentView(
            coordinator: AppCoordinator(model: model, shortcutSettings: settings),
            fileDropController: PanelFileDropController(),
            snipDragSourceController: SnipDragSourceController()
        )
        .environmentObject(model)
        .environmentObject(settings)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 760)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = hostingView

        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        await Task.yield()
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollViews(in: hostingView).count, 1)
        processLifetimePanelSearchWindows.append(window)
    }

    func testListIconCatalogHasUsefulUniqueAvailableSymbols() {
        let icons = SnipListIconOptions.categories.flatMap(\.icons)

        XCTAssertTrue(SnipListIconOptions.categories.allSatisfy { !$0.icons.isEmpty })
        XCTAssertEqual(Set(icons).count, icons.count)
        let unavailableIcons = icons.filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil
        }
        XCTAssertEqual(unavailableIcons, [])
        XCTAssertTrue(SnipListIconOptions.matches("lizard.fill", query: "dinosaur"))
        XCTAssertEqual(icons.filter { $0.contains("magnifyingglass") }, ["magnifyingglass"])
        let representativeSymbols = [
            "paperplane.fill", "flag.fill", "star.fill", "hand.thumbsup.fill", "hand.thumbsdown.fill",
            "dog.fill", "carrot.fill", "motorcycle.fill", "baseball.fill", "tshirt.fill",
            "syringe.fill", "wheelchair", "infinity.circle.fill", "arrow.triangle.branch",
            "square.3.layers.3d", "sidebar.left", "firewall.fill", "circle.dotted"
        ]
        let reviewedEmojiEquivalents = [
            "figure.gymnastics", "figure.wrestling", "figure.equestrian.sports", "figure.rower",
            "figure.waterpolo", "figure.handball", "figure.bowling", "figure.archery",
            "figure.skating", "figure.fishing", "figure.curling", "figure.lacrosse",
            "figure.table.tennis", "figure.badminton", "figure.martial.arts",
            "lifepreserver.fill", "person.text.rectangle.fill", "arrow.3.trianglepath",
            "peacesign", "hand.palm.facing.fill", "graduationcap.fill", "spoon.serving",
            "train.side.front.car", "truck.pickup.side.fill", "cloud.sun.rain.fill",
            "figure.softball", "figure.field.hockey", "l.joystick.fill",
            "suit.spade.fill", "suit.heart.fill", "suit.diamond.fill", "suit.club.fill",
            "coat.fill", "hat.widebrim.fill", "helmet.fill", "ring", "horn.fill",
            "bell.slash.fill", "battery.0percent", "door.left.hand.closed",
            "window.vertical.closed", "bubbles.and.sparkles.fill", "staroflife.fill",
            "sos.circle.fill", "r.circle.fill", "thermometer.medium"
        ]
        let missingRepresentativeSymbols = representativeSymbols.filter { !icons.contains($0) }
        let missingReviewedEmojiEquivalents = reviewedEmojiEquivalents.filter { !icons.contains($0) }
        XCTAssertEqual(missingRepresentativeSymbols, [])
        XCTAssertEqual(missingReviewedEmojiEquivalents, [])
        XCTAssertTrue(SnipListIconOptions.matches("paperplane.fill", query: "rocket"))
    }

    func testDevelopmentBuildIdentityReadsTheSlotFromTheBundleIdentifier() {
        XCTAssertEqual(
            DevelopmentBuildIdentity(bundleIdentifier: "world.sree.snipsnap.dev3")?.slot,
            3
        )
        XCTAssertNil(DevelopmentBuildIdentity(bundleIdentifier: "world.sree.snipsnap"))
        XCTAssertNil(DevelopmentBuildIdentity(bundleIdentifier: "world.sree.snipsnap.dev03"))
        XCTAssertNil(DevelopmentBuildIdentity(bundleIdentifier: "world.sree.snipsnap.dev0"))
        XCTAssertNil(DevelopmentBuildIdentity(bundleIdentifier: "world.sree.snipsnap.preview"))
    }

    func testDevelopmentBuildBadgePaletteLoopsThroughRainbowBlackAndWhite() {
        let tones = (1...18).compactMap {
            DevelopmentBuildIdentity(
                bundleIdentifier: "world.sree.snipsnap.dev\($0)"
            )?.badgeTone
        }

        let cycle = DevelopmentBadgeTone.allCases
        XCTAssertEqual(tones, cycle + cycle)
        XCTAssertTrue(zip(cycle, cycle.dropFirst()).allSatisfy(!=))
        XCTAssertNotEqual(cycle.last, cycle.first)
    }

    func testDevelopmentBadgeLabelsKeepContrastInBothAppearances() {
        for tone in DevelopmentBadgeTone.allCases where tone != .indigo && tone != .black {
            XCTAssertTrue(tone.usesDarkLabel(in: .light))
            XCTAssertTrue(tone.usesDarkLabel(in: .dark))
        }
        XCTAssertFalse(DevelopmentBadgeTone.indigo.usesDarkLabel(in: .light))
        XCTAssertTrue(DevelopmentBadgeTone.indigo.usesDarkLabel(in: .dark))
        XCTAssertFalse(DevelopmentBadgeTone.black.usesDarkLabel(in: .light))
        XCTAssertFalse(DevelopmentBadgeTone.black.usesDarkLabel(in: .dark))
    }

    @MainActor
    private func makeResizeView() -> (window: NSWindow, view: PanelResizeView) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let view = PanelResizeView(
            frame: window.contentView?.bounds ?? .zero,
            screenMouseLocation: { [unowned window] event in
                window.convertPoint(
                    toScreen: event?.locationInWindow ?? CGPoint(x: 150, y: 200)
                )
            }
        )
        window.contentView = view
        return (window, view)
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: type == .leftMouseDragged ? 0 : 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )
        )
    }

    @MainActor
    func testPanelHostingViewDoesNotDriveTheResizableWindowSize() {
        let hostingView = PanelFileDropHostingView(
            rootView: EmptyView(),
            controller: PanelFileDropController(),
            snipDragSourceController: SnipDragSourceController()
        )

        XCTAssertTrue(hostingView.sizingOptions.isEmpty)
    }

    func testPanelFileDropValidationKeepsOnlyExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip SnapPanelDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snip.md")
        try Data("# Snip".utf8).write(to: file)
        let missing = directory.appendingPathComponent("missing.md")

        XCTAssertEqual(
            PanelFileDropValidation.existingFiles(
                in: [directory, missing, URL(string: "https://example.com")!, file]
            ),
            [file]
        )
        XCTAssertEqual(
            PanelFileDropValidation.newFiles(in: [file, file], excluding: []),
            [file]
        )
        XCTAssertTrue(
            PanelFileDropValidation.newFiles(in: [file], excluding: [file]).isEmpty
        )
    }

    func testPanelImagePasteboardPrefersOnePNGPerItem() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("world.sree.snipsnap.image-paste.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        let png = Data([1, 2, 3])
        item.setData(Data([4, 5, 6]), forType: .tiff)
        item.setData(png, forType: .png)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertEqual(
            PanelImagePasteboard.images(from: pasteboard),
            [.data(fileName: "Pasted Image.png", data: png)]
        )
    }

    func testPanelImagePasteboardLeavesTextPasteToTheEditor() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("world.sree.snipsnap.text-paste.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Keep as text", forType: .string))

        XCTAssertTrue(PanelImagePasteboard.images(from: pasteboard).isEmpty)
        XCTAssertTrue(PanelImagePasteboard.containsText(pasteboard))
    }

    func testImagePasteShortcutAllowsCapsLock() {
        XCTAssertTrue(
            PanelImagePasteCommand.matches(modifiers: [.command, .capsLock])
        )
    }

    func testImagePasteShortcutRejectsTextChangingModifiers() {
        XCTAssertFalse(
            PanelImagePasteCommand.matches(modifiers: [.command, .shift])
        )
        XCTAssertFalse(
            PanelImagePasteCommand.matches(modifiers: [.command, .option])
        )
        XCTAssertFalse(
            PanelImagePasteCommand.matches(modifiers: [.command, .control])
        )
    }

    func testPanelImagePasteboardReadsCopiedImageFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip SnapPasteboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Copied.png")
        let data = Data([10, 11, 12])
        try data.write(to: url)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("world.sree.snipsnap.file-paste.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertEqual(PanelImagePasteboard.images(from: pasteboard), [.file(url)])
    }

    func testPanelImagePasteboardPrefersFileURLOverRenderedImageData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip SnapPasteboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Original Name.png")
        try Data([1, 2, 3]).write(to: url)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("world.sree.snipsnap.file-data-paste.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(Data([4, 5, 6]), forType: .png)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertEqual(PanelImagePasteboard.images(from: pasteboard), [.file(url)])
    }

    func testPanelImagePasteboardDoesNotAttachANonImageFileIcon() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip SnapPasteboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Notes.txt")
        try Data("notes".utf8).write(to: url)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("world.sree.snipsnap.non-image-paste.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(Data([1, 2, 3]), forType: .tiff)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertTrue(PanelImagePasteboard.images(from: pasteboard).isEmpty)
    }

    @MainActor
    func testCommandVPastesImagesInPanelTextInput() throws {
        let image = PanelPastedImage.data(fileName: "Pasted Image.png", data: Data([1]))
        var pastedImages: [PanelPastedImage] = []
        let input = PanelMultilineTextInput(
            "Paste here",
            text: .constant(""),
            lineRange: 1...5,
            isFocused: true,
            onFocusChange: { _ in },
            readPastedImages: { [image] },
            pastedContentContainsText: { false },
            onPasteImages: { pastedImages = $0 },
            onSubmit: {}
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: input)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let textField = try XCTUnwrap(findTextField(in: window.contentView))
        XCTAssertTrue(window.makeFirstResponder(textField))
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            )
        )

        NSApp.sendEvent(event)

        XCTAssertEqual(pastedImages, [image])
    }

    @MainActor
    func testShiftReturnInsertsNewlineInPanelTextInputAtTheSelection() throws {
        let value = PanelTextValue("firstsecond")
        var submitted = false
        let input = PanelMultilineTextInput(
            "Add to Inbox…",
            text: Binding(
                get: { value.text },
                set: { value.text = $0 }
            ),
            lineRange: 1...5,
            isFocused: true,
            onFocusChange: { _ in },
            onSubmit: { submitted = true }
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: input)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let textField = try XCTUnwrap(findTextField(in: window.contentView))
        textField.selectText(nil)
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        fieldEditor.setSelectedRange(NSRange(location: 5, length: 0))
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .shift,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )

        NSApp.sendEvent(event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertEqual(value.text, "first\nsecond")
        XCTAssertFalse(submitted)
    }

    @MainActor
    private func findTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let textField = view as? NSTextField { return textField }
        for subview in view.subviews {
            if let textField = findTextField(in: subview) { return textField }
        }
        return nil
    }

    func testPanelPastedImageStagingWritesAnImageFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip SnapPasteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data([7, 8, 9])

        let result = PanelPastedImageStaging.write(
            [.data(fileName: "Screenshot.png", data: data)],
            to: directory
        )
        let urls = try result.get()
        let url = try XCTUnwrap(urls.first)

        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    @MainActor
    func testColdDragPreviewLookupDoesNotDecodeTheFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip SnapDragPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preview.png")
        try Data(repeating: 7, count: 1_024).write(to: file)

        XCTAssertNil(PreviewImageCache.shared.cachedFileThumbnail(url: file, scale: 2))
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(PreviewImageCache.shared.cachedFileThumbnail(url: file, scale: 2))
    }

    @MainActor
    func testClipboardPreviewDownsamplesToTheRequestedPixelSize() async throws {
        let source = NSImage(size: CGSize(width: 1_000, height: 1_000))
        source.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: source.size).fill()
        source.unlockFocus()
        let tiffData = try XCTUnwrap(source.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let preview = await PreviewImageCache.shared.clipboardImage(
            id: UUID(),
            data: pngData,
            size: CGSize(width: 42, height: 42),
            scale: 2
        )
        let largestPixelSide = try XCTUnwrap(preview).representations
            .map { max($0.pixelsWide, $0.pixelsHigh) }
            .max() ?? 0

        XCTAssertLessThanOrEqual(largestPixelSide, 84)
    }

    func testComposerGeometryIgnoresDuplicateAndSubpixelReports() {
        XCTAssertFalse(
            PanelGeometryChange.shouldApply(current: 56, proposed: 56)
        )
        XCTAssertFalse(
            PanelGeometryChange.shouldApply(current: 56, proposed: 56.25)
        )
        XCTAssertTrue(
            PanelGeometryChange.shouldApply(current: 56, proposed: 56.5)
        )
    }

    func testComposerSendAlignsToTheTopOnlyWhenExpanded() {
        XCTAssertEqual(
            PanelComposerLayout.actionAlignment(isExpanded: false),
            VerticalAlignment.center
        )
        XCTAssertEqual(
            PanelComposerLayout.actionAlignment(isExpanded: true),
            VerticalAlignment.top
        )
    }

    func testComposerSendIsAThinInsetCapsule() {
        XCTAssertGreaterThan(
            PanelControlMetrics.sendButtonWidth,
            PanelControlMetrics.sendButtonHeight
        )
        XCTAssertLessThan(
            PanelControlMetrics.sendButtonHeight,
            PanelControlMetrics.floatingRowHeight
        )
        XCTAssertEqual(
            PanelControlMetrics.sendButtonInset,
            (PanelControlMetrics.floatingRowHeight
                - PanelControlMetrics.sendButtonHeight) / 2
        )
    }

    func testTabSelectionUsesTheNearRoundActionProportion() {
        XCTAssertGreaterThan(
            PanelControlMetrics.compactSelectionWidth,
            PanelControlMetrics.compactSelectionHeight
        )
        XCTAssertEqual(
            (PanelControlMetrics.tabItemWidth
                - PanelControlMetrics.compactSelectionWidth) / 2,
            PanelControlMetrics.tabSelectionInset
        )
        XCTAssertEqual(
            (PanelControlMetrics.floatingRowHeight
                - PanelControlMetrics.compactSelectionHeight) / 2,
            PanelControlMetrics.tabSelectionInset
        )
    }

    func testListHeadersAndCardsUseOneHorizontalInset() {
        XCTAssertEqual(PanelListMetrics.horizontalContentInset, 16)
    }

    func testDefaultWindowSizeIsUsable() {
        XCTAssertEqual(AppWindowDefaults.defaultSize.width, 430)
        XCTAssertEqual(AppWindowDefaults.defaultSize.height, 500)
        XCTAssertEqual(
            AppWindowDefaults.defaultSize,
            AppWindowDefaults.windowSize(for: AppWindowDefaults.defaultContentSize)
        )
        XCTAssertEqual(
            AppWindowDefaults.minimumSize,
            AppWindowDefaults.windowSize(for: AppWindowDefaults.minimumContentSize)
        )
        XCTAssertGreaterThanOrEqual(
            AppWindowDefaults.defaultSize.width,
            AppWindowDefaults.minimumSize.width
        )
        XCTAssertGreaterThanOrEqual(
            AppWindowDefaults.defaultSize.height,
            AppWindowDefaults.minimumSize.height
        )
    }

    func testInlineEditorExpandsBeforeItsTextScrolls() {
        XCTAssertGreaterThan(
            PanelInlineEditMetrics.maximumTextLines,
            PanelInlineEditMetrics.minimumTextLines
        )
    }

    func testInlineEditorUsesTheComposerMaximumLineCount() {
        XCTAssertEqual(
            PanelInlineEditMetrics.maximumTextLines,
            PanelComposerMetrics.maximumTextLines
        )
    }

    func testPlainReturnSubmitsTextInput() {
        XCTAssertEqual(PanelTextInputReturnAction.action(for: []), .submit)
    }

    func testShiftReturnInsertsNewlineInTextInput() {
        XCTAssertEqual(PanelTextInputReturnAction.action(for: [.shift]), .insertNewline)
    }

    func testCompactComposerDoesNotTreatItsAlignedFieldAsExpanded() {
        XCTAssertFalse(
            PanelComposerLayout.isExpanded(
                fieldHeight: PanelControlMetrics.floatingRowHeight
            )
        )
        XCTAssertTrue(
            PanelComposerLayout.isExpanded(
                fieldHeight: PanelControlMetrics.floatingRowHeight + 1
            )
        )
    }

    @MainActor
    func testCompactPanelTextInputCentersItsRenderedGlyphLine() throws {
        let input = PanelMultilineTextInput(
            "Add to Inbox…",
            text: .constant("sfafd"),
            lineRange: 1...5,
            isFocused: true,
            onFocusChange: { _ in },
            onSubmit: {}
        )
        let window = NSWindow(
            contentRect: CGRect(
                x: 0,
                y: 0,
                width: 320,
                height: PanelControlMetrics.floatingRowHeight
            ),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: input)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let textField = try XCTUnwrap(findTextField(in: hostingView))
        let cell = try XCTUnwrap(textField.cell)
        let textBounds = cell.titleRect(forBounds: textField.bounds)
        let textBoundsInInput = textField.convert(textBounds, to: hostingView)

        XCTAssertEqual(
            textBoundsInInput.midY,
            hostingView.bounds.midY,
            accuracy: 0.5,
            "Rendered text bounds: \(textBoundsInInput); input bounds: \(hostingView.bounds)"
        )
    }

    func testVisiblePaneResizeHitTestingCoversEveryEdgeAndCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)

        XCTAssertEqual(PanelResizeHitTesting.edges(at: CGPoint(x: 2, y: 200), in: bounds), .left)
        XCTAssertEqual(PanelResizeHitTesting.edges(at: CGPoint(x: 298, y: 200), in: bounds), .right)
        XCTAssertEqual(PanelResizeHitTesting.edges(at: CGPoint(x: 150, y: 2), in: bounds), .bottom)
        XCTAssertEqual(PanelResizeHitTesting.edges(at: CGPoint(x: 150, y: 398), in: bounds), .top)
        XCTAssertEqual(PanelResizeHitTesting.edges(at: CGPoint(x: 8, y: 8), in: bounds), [.left, .bottom])
        XCTAssertEqual(PanelResizeHitTesting.edges(at: CGPoint(x: 292, y: 8), in: bounds), [.right, .bottom])
        XCTAssertEqual(PanelResizeHitTesting.edges(at: CGPoint(x: 8, y: 392), in: bounds), [.left, .top])
        XCTAssertEqual(PanelResizeHitTesting.edges(at: CGPoint(x: 292, y: 392), in: bounds), [.right, .top])
        XCTAssertTrue(PanelResizeHitTesting.edges(at: CGPoint(x: 150, y: 200), in: bounds).isEmpty)
    }

    func testVisiblePaneResizeRimStaysCloseToTheGlassEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)

        XCTAssertEqual(
            PanelResizeHitTesting.edges(at: CGPoint(x: 4, y: 200), in: bounds),
            .left
        )
        XCTAssertTrue(
            PanelResizeHitTesting.edges(at: CGPoint(x: 6, y: 200), in: bounds).isEmpty
        )
        XCTAssertTrue(
            PanelResizeHitTesting.edges(at: CGPoint(x: -1, y: 200), in: bounds).isEmpty
        )
    }

    func testVisiblePaneResizeTrackingRegionsCoverTheRimWithoutOverlap() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let regions = PanelResizeHitTesting.regions(in: bounds)

        XCTAssertEqual(regions.count, 8)
        for (index, region) in regions.enumerated() {
            XCTAssertFalse(region.rect.isEmpty)
            XCTAssertFalse(region.edges.isEmpty)
            for other in regions.dropFirst(index + 1) {
                XCTAssertTrue(
                    region.rect.intersection(other.rect).isEmpty,
                    "Resize cursor regions must not compete for the same point"
                )
            }
        }
    }

    func testVisiblePaneResizeKeepsOppositeEdgesAnchored() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 500)
        let limits = CGSize(width: 200, height: 250)
        let maximum = CGSize(width: 900, height: 900)

        let leftBottom = PanelResizeGeometry.frame(
            from: frame,
            dragDelta: CGPoint(x: -40, y: -30),
            edges: [.left, .bottom],
            minimumSize: limits,
            maximumSize: maximum
        )
        XCTAssertEqual(leftBottom, CGRect(x: 60, y: 170, width: 440, height: 530))

        let rightTop = PanelResizeGeometry.frame(
            from: frame,
            dragDelta: CGPoint(x: 50, y: 60),
            edges: [.right, .top],
            minimumSize: limits,
            maximumSize: maximum
        )
        XCTAssertEqual(rightTop, CGRect(x: 100, y: 200, width: 450, height: 560))
    }

    func testVisiblePaneResizeClampsAtMinimumSize() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 500)
        let resized = PanelResizeGeometry.frame(
            from: frame,
            dragDelta: CGPoint(x: 350, y: 400),
            edges: [.left, .bottom],
            minimumSize: CGSize(width: 300, height: 350),
            maximumSize: CGSize(width: 900, height: 900)
        )

        XCTAssertEqual(resized, CGRect(x: 200, y: 350, width: 300, height: 350))
    }

    func testVisiblePaneResizeClampsAtMaximumSize() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 500)
        let resized = PanelResizeGeometry.frame(
            from: frame,
            dragDelta: CGPoint(x: 900, y: 900),
            edges: [.right, .top],
            minimumSize: CGSize(width: 300, height: 350),
            maximumSize: CGSize(width: 600, height: 650)
        )

        XCTAssertEqual(resized, CGRect(x: 100, y: 200, width: 600, height: 650))
    }

    @MainActor
    func testVisiblePaneResizeViewTakesOnlyPerimeterInput() {
        let view = PanelResizeView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 400)
        )

        XCTAssertNil(view.hitTest(CGPoint(x: 150, y: 200)))
        XCTAssertTrue(view.hitTest(CGPoint(x: 2, y: 200)) === view)
        XCTAssertTrue(view.hitTest(CGPoint(x: 292, y: 392)) === view)
    }

    @MainActor
    func testVisiblePaneResizeTracksHoverWhileTheAppIsInactive() throws {
        let (_, view) = makeResizeView()

        view.updateTrackingAreas()
        let resizeAreas = view.trackingAreas.filter {
            $0.options.contains(.mouseEnteredAndExited)
        }
        let leftArea = try XCTUnwrap(
            resizeAreas.first { area in
                (area.userInfo?[PanelResizeView.trackingEdgesKey] as? Int)
                    == PanelResizeEdges.left.rawValue
            }
        )

        XCTAssertEqual(resizeAreas.count, 8)
        XCTAssertTrue(resizeAreas.allSatisfy {
            $0.options.contains(.activeAlways)
        })

        NSCursor.arrow.set()
        view.mouseEntered(with: PanelResizeTrackingEvent(trackingArea: leftArea))

        XCTAssertEqual(
            NSCursor.current.image.tiffRepresentation,
            NSCursor.frameResize(position: .left, directions: .all)
                .image.tiffRepresentation
        )
    }

    @MainActor
    func testVisiblePaneResizeRefreshesHoverWhenTrackingAreasChange() throws {
        let (_, view) = makeResizeView()
        view.updateTrackingAreas()
        let leftArea = try XCTUnwrap(
            view.trackingAreas.first { area in
                (area.userInfo?[PanelResizeView.trackingEdgesKey] as? Int)
                    == PanelResizeEdges.left.rawValue
            }
        )
        view.mouseEntered(with: PanelResizeTrackingEvent(trackingArea: leftArea))

        view.updateTrackingAreas()

        XCTAssertEqual(
            NSCursor.current.image.tiffRepresentation,
            NSCursor.arrow.image.tiffRepresentation
        )
    }

    @MainActor
    func testVisiblePaneResizeDoesNotClaimCursorOnAnUnrelatedTrackingUpdate() {
        let (_, view) = makeResizeView()
        NSCursor.iBeam.set()

        view.updateTrackingAreas()

        XCTAssertEqual(
            NSCursor.current.image.tiffRepresentation,
            NSCursor.iBeam.image.tiffRepresentation
        )
    }

    @MainActor
    func testVisiblePaneResizeViewKeepsDirectionalCursorForActiveDrag() throws {
        let (window, view) = makeResizeView()
        let edgeEvent = try mouseEvent(.leftMouseDown, at: CGPoint(x: 2, y: 200), in: window)
        let dragEvent = try mouseEvent(.leftMouseDragged, at: CGPoint(x: 20, y: 200), in: window)
        let upEvent = try mouseEvent(.leftMouseUp, at: CGPoint(x: 20, y: 200), in: window)

        view.mouseDown(with: edgeEvent)
        XCTAssertFalse(window.areCursorRectsEnabled)
        NSCursor.arrow.set()
        view.mouseDragged(with: dragEvent)

        XCTAssertEqual(
            NSCursor.current.image.tiffRepresentation,
            NSCursor.frameResize(position: .left, directions: .all)
                .image.tiffRepresentation
        )

        view.mouseUp(with: upEvent)
        XCTAssertTrue(window.areCursorRectsEnabled)
    }

    @MainActor
    func testVisiblePaneResizeViewChangesTheWindowFrameDuringDrag() throws {
        let (window, view) = makeResizeView()
        let downEvent = try mouseEvent(
            .leftMouseDown,
            at: CGPoint(x: 298, y: 200),
            in: window
        )
        let dragEvent = try mouseEvent(
            .leftMouseDragged,
            at: CGPoint(x: 318, y: 200),
            in: window
        )
        let upEvent = try mouseEvent(
            .leftMouseUp,
            at: CGPoint(x: 318, y: 200),
            in: window
        )

        view.mouseDown(with: downEvent)
        view.mouseDragged(with: dragEvent)
        view.mouseUp(with: upEvent)

        XCTAssertEqual(window.frame.width, 320)
    }

    @MainActor
    func testVisiblePaneResizeClearsStaleHoverAfterDraggingAwayFromTheEdge() throws {
        let (window, view) = makeResizeView()
        view.updateTrackingAreas()
        let leftArea = try XCTUnwrap(
            view.trackingAreas.first { area in
                (area.userInfo?[PanelResizeView.trackingEdgesKey] as? Int)
                    == PanelResizeEdges.left.rawValue
            }
        )
        let downEvent = try mouseEvent(
            .leftMouseDown,
            at: CGPoint(x: 2, y: 200),
            in: window
        )
        let dragEvent = try mouseEvent(
            .leftMouseDragged,
            at: CGPoint(x: 20, y: 200),
            in: window
        )
        let upEvent = try mouseEvent(
            .leftMouseUp,
            at: CGPoint(x: 100, y: 200),
            in: window
        )

        view.mouseEntered(with: PanelResizeTrackingEvent(trackingArea: leftArea))
        view.mouseDown(with: downEvent)
        view.mouseDragged(with: dragEvent)
        view.mouseUp(with: upEvent)

        XCTAssertEqual(
            NSCursor.current.image.tiffRepresentation,
            NSCursor.arrow.image.tiffRepresentation
        )
    }

    @MainActor
    func testVisiblePaneResizeRefreshesHoverWhenEscapeCancelsTheDrag() throws {
        let (window, view) = makeResizeView()
        view.updateTrackingAreas()
        let leftArea = try XCTUnwrap(
            view.trackingAreas.first { area in
                (area.userInfo?[PanelResizeView.trackingEdgesKey] as? Int)
                    == PanelResizeEdges.left.rawValue
            }
        )
        let downEvent = try mouseEvent(
            .leftMouseDown,
            at: CGPoint(x: 2, y: 200),
            in: window
        )
        let dragEvent = try mouseEvent(
            .leftMouseDragged,
            at: CGPoint(x: 20, y: 200),
            in: window
        )

        view.mouseEntered(with: PanelResizeTrackingEvent(trackingArea: leftArea))
        view.mouseDown(with: downEvent)
        view.mouseDragged(with: dragEvent)
        view.cancelOperation(nil)

        XCTAssertEqual(
            NSCursor.current.image.tiffRepresentation,
            NSCursor.arrow.image.tiffRepresentation
        )
    }

    @MainActor
    func testVisiblePaneResizeForwardsEscapeWhenNoDragIsActive() {
        let view = PanelResizeView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let responder = PanelResizeCancelResponder()
        view.nextResponder = responder

        view.cancelOperation(nil)

        XCTAssertTrue(responder.didCancel)
    }

    @MainActor
    func testVisiblePaneResizeRestoresCursorManagementWhenRemovedDuringDrag() throws {
        let (window, view) = makeResizeView()
        let edgeEvent = try mouseEvent(.leftMouseDown, at: CGPoint(x: 2, y: 200), in: window)

        view.mouseDown(with: edgeEvent)
        XCTAssertFalse(window.areCursorRectsEnabled)

        view.removeFromSuperview()

        XCTAssertTrue(window.areCursorRectsEnabled)
    }

    @MainActor
    func testSnipSnapPanelLetsExplicitSwiftUISurfacesOwnWindowMovement() {
        let contentViewController = NSViewController()
        let panel = SnipSnapPanel.make(
            contentViewController: contentViewController,
            frameAutosaveName: nil
        )

        XCTAssertFalse(panel.styleMask.contains(.resizable))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertFalse(panel.styleMask.contains(.closable))
        XCTAssertFalse(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(panel.styleMask.contains(.utilityWindow))
        XCTAssertEqual(panel.title, "Snip Snap")
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertTrue(panel.isExcludedFromWindowsMenu)
        XCTAssertEqual(panel.minSize, AppWindowDefaults.minimumSize)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertTrue(panel.contentViewController === contentViewController)
    }

    @MainActor
    func testSnipSnapPanelRestoresItsSavedSizeAndPosition() {
        let autosaveName = NSWindow.FrameAutosaveName("PanelTests-\(UUID().uuidString)")
        defer { NSWindow.removeFrame(usingName: autosaveName) }
        let savedFrame = NSRect(x: 180, y: 220, width: 510, height: 740)
        let firstPanel = SnipSnapPanel.make(
            contentViewController: NSViewController(),
            frameAutosaveName: autosaveName
        )
        firstPanel.setFrame(savedFrame, display: false)
        firstPanel.saveFrame(usingName: autosaveName)
        firstPanel.setFrameAutosaveName("")

        let restoredPanel = SnipSnapPanel.make(
            contentViewController: NSViewController(),
            frameAutosaveName: autosaveName
        )

        XCTAssertTrue(restoredPanel.restoredSavedFrame)
        XCTAssertEqual(restoredPanel.frame, savedFrame)
        XCTAssertEqual(restoredPanel.frameAutosaveName, autosaveName)
    }

    @MainActor
    func testSnipSnapPanelKeepsTheDefaultSizeWhenThereIsNoSavedFrame() {
        let autosaveName = NSWindow.FrameAutosaveName("PanelTests-\(UUID().uuidString)")
        defer { NSWindow.removeFrame(usingName: autosaveName) }
        let contentViewController = NSHostingController(
            rootView: EmptyView()
                .frame(
                    minWidth: AppWindowDefaults.minimumContentSize.width,
                    minHeight: AppWindowDefaults.minimumContentSize.height
                )
        )

        let panel = SnipSnapPanel.make(
            contentViewController: contentViewController,
            frameAutosaveName: autosaveName
        )

        XCTAssertFalse(panel.restoredSavedFrame)
        XCTAssertEqual(panel.frame.size, AppWindowDefaults.defaultSize)
    }

    @MainActor
    func testSnipSnapPanelHasNoSeparateNativeTitleSurface() {
        let panel = SnipSnapPanel.make(
            contentViewController: NSViewController(),
            frameAutosaveName: nil
        )

        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertNil(panel.standardWindowButton(.closeButton))
    }

    @MainActor
    func testSnipSnapPanelKeepsTrafficLightsHiddenAfterContentLayout() {
        let contentViewController = NSHostingController(
            rootView: List { Text("Item") }
        )
        let panel = SnipSnapPanel.make(
            contentViewController: contentViewController,
            frameAutosaveName: nil
        )
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertNil(panel.standardWindowButton(.closeButton))
        XCTAssertNil(panel.standardWindowButton(.miniaturizeButton))
        XCTAssertNil(panel.standardWindowButton(.zoomButton))
    }

    @MainActor
    func testPanelContentTracksResize() {
        let contentViewController = NSViewController()
        let panel = SnipSnapPanel.make(
            contentViewController: contentViewController,
            frameAutosaveName: nil
        )
        let resized = NSSize(width: 480, height: 700)

        panel.setContentSize(resized)
        panel.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(panel.contentView?.bounds.size, resized)
        XCTAssertEqual(contentViewController.view.frame.size, resized)
        XCTAssertTrue(panel.contentViewController === contentViewController)
    }

    @MainActor
    func testSnipDragDoesNotRunAlongsideAnotherDragGesture() throws {
        let controller = SnipDragSourceController()
        let hostView = NSView()
        controller.attach(to: hostView)
        let snipPan = try XCTUnwrap(
            hostView.gestureRecognizers.first { $0 is NSPanGestureRecognizer }
        )
        let otherDrag = NSPanGestureRecognizer()

        XCTAssertFalse(
            controller.gestureRecognizer(
                snipPan,
                shouldRecognizeSimultaneouslyWith: otherDrag
            )
        )
        XCTAssertTrue(snipPan.canPrevent(otherDrag))
        XCTAssertFalse(snipPan.canBePrevented(by: otherDrag))
    }

    @MainActor
    func testStickyHeaderBlocksTheSnipHiddenBelowIt() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let host = try XCTUnwrap(window.contentView)
        let snipView = NSView(frame: NSRect(x: 0, y: 180, width: 300, height: 100))
        let headerView = NSView(frame: NSRect(x: 0, y: 240, width: 300, height: 40))
        host.addSubview(snipView)
        host.addSubview(headerView)
        let controller = SnipDragSourceController()
        let payload = SnipDragPayload(ids: [UUID()], text: "Hidden snip")
        controller.updateRegion(
            id: UUID(),
            view: snipView,
            payload: payload,
            onBegan: {},
            onMoved: { _ in },
            onEnded: { _, _ in }
        )
        controller.updateBlockingView(id: UUID(), view: headerView)

        XCTAssertNil(controller.payload(atWindowPoint: NSPoint(x: 150, y: 260)))
        XCTAssertEqual(controller.payload(atWindowPoint: NSPoint(x: 150, y: 220)), payload)
    }

    @MainActor
    func testTabBarBlocksTheSnipHiddenBelowItAcrossItsFullWidth() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let host = try XCTUnwrap(window.contentView)
        let snipView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let tabBarView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        host.addSubview(snipView)
        host.addSubview(tabBarView)
        let controller = SnipDragSourceController()
        let payload = SnipDragPayload(ids: [UUID()], text: "Hidden snip")
        controller.updateRegion(
            id: UUID(),
            view: snipView,
            payload: payload,
            onBegan: {},
            onMoved: { _ in },
            onEnded: { _, _ in }
        )
        controller.updateBlockingView(id: UUID(), view: tabBarView)

        XCTAssertNil(controller.payload(atWindowPoint: NSPoint(x: 5, y: 20)))
        XCTAssertNil(controller.payload(atWindowPoint: NSPoint(x: 150, y: 20)))
        XCTAssertNil(controller.payload(atWindowPoint: NSPoint(x: 295, y: 20)))
        XCTAssertEqual(controller.payload(atWindowPoint: NSPoint(x: 150, y: 60)), payload)
    }

    @MainActor
    func testResizeRimBlocksTheSnipHiddenBelowIt() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let host = try XCTUnwrap(window.contentView)
        let snipView = NSView(frame: host.bounds)
        let resizeView = PanelResizeView(frame: host.bounds)
        host.addSubview(snipView)
        host.addSubview(resizeView)
        let controller = SnipDragSourceController()
        controller.attach(to: host)
        let payload = SnipDragPayload(ids: [UUID()], text: "Hidden snip")
        controller.updateRegion(
            id: UUID(),
            view: snipView,
            payload: payload,
            onBegan: {},
            onMoved: { _ in },
            onEnded: { _, _ in }
        )

        XCTAssertNil(controller.payload(atWindowPoint: NSPoint(x: 2, y: 150)))
        XCTAssertEqual(controller.payload(atWindowPoint: NSPoint(x: 150, y: 150)), payload)
    }

    func testListBottomPaddingKeepsTheComposerHeightScrollable() {
        XCTAssertEqual(
            PanelOverlayLayout.listBottomPadding(composerHeight: 56),
            66
        )
        XCTAssertEqual(
            PanelOverlayLayout.listBottomPadding(composerHeight: -20),
            PanelOverlayLayout.listBaseBottomPadding
        )
    }

    func testPanelEdgeStylesUseTheSharedThicknessScale() {
        XCTAssertEqual(PanelEdgeThickness.subtle, 0.5)
        XCTAssertEqual(PanelEdgeThickness.regular, 0.75)
        XCTAssertEqual(PanelEdgeThickness.strong, 1)
        XCTAssertEqual(PanelEdgeThickness.prominent, 1.5)
        XCTAssertEqual(PanelGlassEdgeState.hidden.style.width, 0)
        XCTAssertEqual(PanelGlassEdgeState.standard.style.width, 0.5)
        XCTAssertEqual(PanelGlassEdgeState.emphasized.style.width, 0.75)
        XCTAssertEqual(PanelGlassEdgeState.focused.style.width, 1)
        XCTAssertEqual(PanelEdgeStyle.content.width, 0.75)
        XCTAssertEqual(PanelEdgeStyle.media.width, 0.75)
        XCTAssertEqual(PanelEdgeStyle.selected.width, 1)
        XCTAssertEqual(PanelEdgeStyle.dropTarget.width, 1.5)
    }

    func testPanelEdgeStylesUseSemanticColors() {
        XCTAssertEqual(PanelEdgeStyle.hidden.color, .clear)
        XCTAssertEqual(PanelGlassEdgeState.hidden.style.color, .clear)
        XCTAssertEqual(PanelGlassEdgeState.standard.style.color, SnipSnapColors.glassEdge)
        XCTAssertEqual(
            PanelGlassEdgeState.emphasized.style.color,
            SnipSnapColors.emphasizedGlassEdge
        )
        XCTAssertEqual(PanelGlassEdgeState.focused.style.color, SnipSnapColors.focusedGlassEdge)
        XCTAssertEqual(PanelEdgeStyle.content.color, SnipSnapColors.contentCardEdge)
        XCTAssertEqual(PanelEdgeStyle.media.color, SnipSnapColors.attachmentEdge)
        XCTAssertEqual(PanelEdgeStyle.selected.color, SnipSnapColors.selectionEdge)
        XCTAssertEqual(PanelEdgeStyle.dropTarget.color, SnipSnapColors.dropTargetEdge)
        XCTAssertNotEqual(
            PanelGlassEdgeState.standard.style.color,
            PanelGlassEdgeState.emphasized.style.color
        )
        XCTAssertNotEqual(
            PanelGlassEdgeState.emphasized.style.color,
            PanelGlassEdgeState.focused.style.color
        )
    }

    func testPrimaryActionTintUsesExactThemeContrast() {
        XCTAssertEqual(SnipSnapColors.primaryActionTint(for: .light), .black)
        XCTAssertEqual(SnipSnapColors.primaryActionTint(for: .dark), .white)
    }

    func testElevatedListHeaderTintUsesTheInversePrimaryAsset() {
        XCTAssertEqual(
            SnipSnapColors.elevatedListHeaderGlassTint,
            Color("InversePrimary").opacity(0.20)
        )
    }

    @MainActor
    func testPanelContextMenuKeepsActionsAndDisabledState() throws {
        var actionCount = 0
        let menu = NSMenu()
        menu.addPanelAction("Copy") { actionCount += 1 }
        menu.addPanelAction("Merge Snips", isEnabled: false) {}
        menu.addPanelSubmenu("Move to") { submenu in
            submenu.addPanelAction("Inbox") {}
        }

        let copyItem = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(
            NSApp.sendAction(copyItem.action!, to: copyItem.target, from: copyItem)
        )
        XCTAssertEqual(actionCount, 1)
        XCTAssertFalse(menu.items[1].isEnabled)
        XCTAssertEqual(menu.items[2].submenu?.items.map(\.title), ["Inbox"])
    }

    @MainActor
    func testPanelCardInteractionRegionPassesPrimaryClicksThroughToCard() {
        let source = PanelCardInteractionRegionView(
            controller: PanelCardInteractionController(),
            id: UUID(),
            contextMenu: PanelCardContextMenu(
                makeMenu: NSMenu.init,
                onOpen: {},
                onClose: {}
            )
        )
        source.frame = NSRect(x: 0, y: 0, width: 200, height: 80)

        XCTAssertNil(source.hitTest(NSPoint(x: 100, y: 40)))
    }

    @MainActor
    func testPanelCardInteractionControllerClearsOnlyWhenClickingAwayFromCards() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = host
        let card = NSView(frame: NSRect(x: 20, y: 40, width: 200, height: 80))
        host.addSubview(card)
        let id = UUID()
        let controller = PanelCardInteractionController()
        var clearCount = 0
        controller.configure { clearCount += 1 }
        controller.attach(to: host)
        controller.updateRegion(
            id: id,
            view: card
        )

        let clipView = NSClipView(frame: NSRect(x: 240, y: 20, width: 40, height: 60))
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 160))
        let clippedCard = NSView(frame: NSRect(x: 0, y: 80, width: 40, height: 40))
        host.addSubview(clipView)
        clipView.documentView = documentView
        documentView.addSubview(clippedCard)
        controller.updateRegion(
            id: UUID(),
            view: clippedCard
        )

        let cardPoint = card.convert(NSPoint(x: 100, y: 40), to: nil)
        XCTAssertEqual(controller.regionID(atWindowPoint: cardPoint), id)
        controller.clearSelectionIfClickAway(atWindowPoint: cardPoint)
        XCTAssertEqual(clearCount, 0)

        controller.clearSelectionIfClickAway(atWindowPoint: NSPoint(x: 280, y: 180))
        XCTAssertEqual(clearCount, 1)

        let clippedPoint = clippedCard.convert(NSPoint(x: 20, y: 20), to: nil)
        XCTAssertNil(controller.regionID(atWindowPoint: clippedPoint))
    }

    @MainActor
    func testPanelCardInteractionControllerTreatsControlClickAsContextClick() throws {
        XCTAssertTrue(
            PanelCardInteractionController.isContextClick(
                buttonNumber: 0,
                modifiers: .control
            )
        )
        XCTAssertTrue(
            PanelCardInteractionController.isContextClick(
                buttonNumber: 1,
                modifiers: []
            )
        )
        XCTAssertFalse(
            PanelCardInteractionController.isPrimaryClick(
                buttonNumber: 0,
                modifiers: .control
            )
        )
        XCTAssertTrue(
            PanelCardInteractionController.isPrimaryClick(
                buttonNumber: 0,
                modifiers: []
            )
        )
        let nonMouseEvent = try XCTUnwrap(NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ))
        XCTAssertFalse(PanelCardInteractionController.isContextClick(event: nonMouseEvent))
        XCTAssertFalse(PanelCardInteractionController.isPrimaryClick(event: nonMouseEvent))
    }

    @MainActor
    func testPanelCardInteractionRegionHandlesRightMouseEvent() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = host
        var menuBuildCount = 0
        let controller = PanelCardInteractionController()
        controller.attach(to: host)
        let card = PanelCardInteractionRegionView(
            controller: controller,
            id: UUID(),
            contextMenu: PanelCardContextMenu(
                makeMenu: {
                    menuBuildCount += 1
                    return NSMenu()
                },
                onOpen: {},
                onClose: {}
            )
        )
        card.frame = NSRect(x: 20, y: 40, width: 200, height: 80)
        host.addSubview(card)

        let location = NSPoint(x: 120, y: 80)
        XCTAssertNotNil(controller.regionID(atWindowPoint: location))
        card.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: location, in: window))

        XCTAssertEqual(menuBuildCount, 1)
    }

    @MainActor
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews)
    }
}
