import XCTest
import AppKit
import SwiftUI
@testable import SnipSnap

private final class PanelResizeTrackingEvent: NSEvent {
    private let generatingTrackingArea: NSTrackingArea
    private let eventLocation: NSPoint

    override var trackingArea: NSTrackingArea? { generatingTrackingArea }
    override var locationInWindow: NSPoint { eventLocation }

    init(trackingArea: NSTrackingArea, locationInWindow: NSPoint) {
        generatingTrackingArea = trackingArea
        eventLocation = locationInWindow
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PanelTests: XCTestCase {
    @MainActor
    private func makeResizeView() -> (window: NSWindow, view: PanelResizeView) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let view = PanelResizeView(frame: window.contentView?.bounds ?? .zero)
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
            clipDragSourceController: ClipDragSourceController()
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
        let file = directory.appendingPathComponent("clip.md")
        try Data("# Clip".utf8).write(to: file)
        let missing = directory.appendingPathComponent("missing.md")

        XCTAssertEqual(
            PanelFileDropValidation.existingFiles(
                in: [directory, missing, URL(string: "https://example.com")!, file]
            ),
            [file]
        )
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

    func testDefaultWindowIsCompactAndUsable() {
        XCTAssertEqual(AppWindowDefaults.defaultSize.width, 430)
        XCTAssertEqual(AppWindowDefaults.defaultSize.height, 576)
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

    func testVisiblePaneResizeRimProvidesAForgivingHoverTarget() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)

        XCTAssertEqual(
            PanelResizeHitTesting.edges(at: CGPoint(x: 9, y: 200), in: bounds),
            .left
        )
        XCTAssertTrue(
            PanelResizeHitTesting.edges(at: CGPoint(x: 11, y: 200), in: bounds).isEmpty
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
    func testVisiblePaneResizeTrackingAreasDriveCursorByIdentity() throws {
        let (_, view) = makeResizeView()
        view.updateTrackingAreas()
        let resizeTrackingAreas = view.trackingAreas.filter {
            $0.options.contains(.cursorUpdate)
        }

        XCTAssertEqual(resizeTrackingAreas.count, 8)
        XCTAssertTrue(resizeTrackingAreas.allSatisfy {
            $0.options.contains(.activeInActiveApp)
        })
        XCTAssertEqual(
            Set(resizeTrackingAreas.compactMap { area in
                (area.userInfo?[PanelResizeView.trackingEdgesKey] as? Int)
            }),
            Set(PanelResizeHitTesting.regions(in: view.bounds).map(\.edges.rawValue))
        )
        let leftArea = try XCTUnwrap(
            resizeTrackingAreas.first { area in
                (area.userInfo?[PanelResizeView.trackingEdgesKey] as? Int)
                    == PanelResizeEdges.left.rawValue
            }
        )
        let event = PanelResizeTrackingEvent(
            trackingArea: leftArea,
            locationInWindow: CGPoint(x: -1, y: -1)
        )

        NSCursor.arrow.set()
        view.cursorUpdate(with: event)

        XCTAssertEqual(
            NSCursor.current.image.tiffRepresentation,
            NSCursor.frameResize(position: .left, directions: .all)
                .image.tiffRepresentation
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
        let panel = SnipSnapPanel.make(contentViewController: contentViewController)

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
    func testSnipSnapPanelHasNoSeparateNativeTitleSurface() {
        let panel = SnipSnapPanel.make(contentViewController: NSViewController())

        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertNil(panel.standardWindowButton(.closeButton))
    }

    @MainActor
    func testSnipSnapPanelKeepsTrafficLightsHiddenAfterContentLayout() {
        let contentViewController = NSHostingController(
            rootView: List { Text("Item") }
        )
        let panel = SnipSnapPanel.make(contentViewController: contentViewController)
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
        let panel = SnipSnapPanel.make(contentViewController: contentViewController)
        let resized = NSSize(width: 480, height: 700)

        panel.setContentSize(resized)
        panel.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(panel.contentView?.bounds.size, resized)
        XCTAssertEqual(contentViewController.view.frame.size, resized)
        XCTAssertTrue(panel.contentViewController === contentViewController)
    }

    @MainActor
    func testClipDragDoesNotRunAlongsideAnotherDragGesture() throws {
        let controller = ClipDragSourceController()
        let hostView = NSView()
        controller.attach(to: hostView)
        let clipPan = try XCTUnwrap(
            hostView.gestureRecognizers.first { $0 is NSPanGestureRecognizer }
        )
        let otherDrag = NSPanGestureRecognizer()

        XCTAssertFalse(
            controller.gestureRecognizer(
                clipPan,
                shouldRecognizeSimultaneouslyWith: otherDrag
            )
        )
        XCTAssertTrue(clipPan.canPrevent(otherDrag))
        XCTAssertFalse(clipPan.canBePrevented(by: otherDrag))
    }

    @MainActor
    func testStickyHeaderBlocksTheClipHiddenBelowIt() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let host = try XCTUnwrap(window.contentView)
        let clipView = NSView(frame: NSRect(x: 0, y: 180, width: 300, height: 100))
        let headerView = NSView(frame: NSRect(x: 0, y: 240, width: 300, height: 40))
        host.addSubview(clipView)
        host.addSubview(headerView)
        let controller = ClipDragSourceController()
        let payload = ClipDragPayload(ids: [UUID()], text: "Hidden clip")
        controller.updateRegion(
            id: UUID(),
            view: clipView,
            payload: payload,
            onBegan: {},
            onEnded: { _ in }
        )
        controller.updateBlockingView(id: UUID(), view: headerView)

        XCTAssertNil(controller.payload(atWindowPoint: NSPoint(x: 150, y: 260)))
        XCTAssertEqual(controller.payload(atWindowPoint: NSPoint(x: 150, y: 220)), payload)
    }

    @MainActor
    func testTabBarBlocksTheClipHiddenBelowItAcrossItsFullWidth() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let host = try XCTUnwrap(window.contentView)
        let clipView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let tabBarView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        host.addSubview(clipView)
        host.addSubview(tabBarView)
        let controller = ClipDragSourceController()
        let payload = ClipDragPayload(ids: [UUID()], text: "Hidden clip")
        controller.updateRegion(
            id: UUID(),
            view: clipView,
            payload: payload,
            onBegan: {},
            onEnded: { _ in }
        )
        controller.updateBlockingView(id: UUID(), view: tabBarView)

        XCTAssertNil(controller.payload(atWindowPoint: NSPoint(x: 5, y: 20)))
        XCTAssertNil(controller.payload(atWindowPoint: NSPoint(x: 150, y: 20)))
        XCTAssertNil(controller.payload(atWindowPoint: NSPoint(x: 295, y: 20)))
        XCTAssertEqual(controller.payload(atWindowPoint: NSPoint(x: 150, y: 60)), payload)
    }

    @MainActor
    func testResizeRimBlocksTheClipHiddenBelowIt() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let host = try XCTUnwrap(window.contentView)
        let clipView = NSView(frame: host.bounds)
        let resizeView = PanelResizeView(frame: host.bounds)
        host.addSubview(clipView)
        host.addSubview(resizeView)
        let controller = ClipDragSourceController()
        controller.attach(to: host)
        let payload = ClipDragPayload(ids: [UUID()], text: "Hidden clip")
        controller.updateRegion(
            id: UUID(),
            view: clipView,
            payload: payload,
            onBegan: {},
            onEnded: { _ in }
        )

        XCTAssertNil(controller.payload(atWindowPoint: NSPoint(x: 2, y: 150)))
        XCTAssertEqual(controller.payload(atWindowPoint: NSPoint(x: 150, y: 150)), payload)
    }

    @MainActor
    func testInboxAutoScrollUsesTheNativeScrollViewWithoutPublishedListState() {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 100)
        )
        scrollView.documentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 1_000)
        )
        let scroller = InboxListScroller()
        scroller.attach(scrollView)

        scroller.scrollTo(y: 120)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 120)

        scroller.scrollTo(y: 0)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0)
    }

    @MainActor
    func testPinnedSectionFollowsTheLatestHeaderAboveTheViewport() {
        let geometry = InboxListGeometry()
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        geometry.record(
            CGRect(x: 0, y: 0, width: 100, height: 32),
            for: .heading(firstSectionID)
        )
        geometry.record(
            CGRect(x: 0, y: 200, width: 100, height: 32),
            for: .heading(secondSectionID)
        )

        geometry.updateScroll(
            .init(
                visibleOrigin: CGPoint(x: 0, y: 150),
                contentHeight: 400,
                viewportHeight: 100
            )
        )
        XCTAssertEqual(geometry.pinnedSectionIDs(), [firstSectionID])

        geometry.updateScroll(
            .init(
                visibleOrigin: CGPoint(x: 0, y: 220),
                contentHeight: 400,
                viewportHeight: 100
            )
        )
        XCTAssertEqual(geometry.pinnedSectionIDs(), [secondSectionID])
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

    func testTopLevelGlassUsesTheSharedFaintEdge() {
        XCTAssertEqual(PanelSurfaceStyle.glassEdgeWidth, 0.5)
    }

    func testPrimaryActionTintUsesExactThemeContrast() {
        XCTAssertEqual(SnipSnapColors.primaryActionTint(for: .light), .black)
        XCTAssertEqual(SnipSnapColors.primaryActionTint(for: .dark), .white)
    }
}
