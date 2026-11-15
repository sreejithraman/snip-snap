import Observation
import ImageIO
import SnipSnapCore
import SnipSnapCloud
import SnipSnapPersistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnapiOS

@MainActor
final class ClipboardRowPreviewTests: XCTestCase {
    func testInlineImageRowReusesThumbnailsAfterRefreshAndCopiesOriginalBytes() async throws {
        let previousPasteboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousPasteboard }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = try [(1024, 512), (512, 1024), (1024, 1024)].map {
            try XCTUnwrap(UIImage(cgImage: thumbnailTestImage(width: $0.0, height: $0.1)).pngData())
        }
        let entry = ClipboardEntry(items: originals.map {
            .init(representations: [.init(type: UTType.png.identifier, data: $0)])
        }, plainText: "Three original clipboard images")
        let store = ClipboardHistoryStore(url: root.appendingPathComponent("clipboard.json"))
        _ = try await store.insert(entry)
        let preferencesName = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: preferencesName))
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let model = IOSClipboardModel(rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly), preferences: preferences)
        await model.load()
        let host = UIHostingController(rootView: ClipboardItemRow(entry: entry, model: model, onCopy: {}))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let size = CGSize(width: 64, height: 64)
        let scale = host.traitCollection.displayScale
        let keys = (0..<3).map { ClipboardImageThumbnailID(entry: entry, representationIndex: $0) }
        func cached() -> [CGImage] {
            keys.compactMap { AttachmentThumbnailCache.shared.cachedClipboardImage(id: $0, size: size, scale: scale) }
        }
        _ = await TestReadiness.wait { cached().count == 3 }
        let before = cached()
        XCTAssertEqual(before.count, 3)
        let revision = model.filePreviewRevision
        await model.load()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(model.filePreviewRevision, revision)
        XCTAssertEqual(cached().count, 3)
        XCTAssertTrue(zip(before, cached()).allSatisfy { $0 === $1 })
        XCTAssertTrue(cached().allSatisfy { max($0.width, $0.height) <= Int(64 * scale) })
        await model.copy(entry)
        XCTAssertEqual(UIPasteboard.general.data(forPasteboardType: UTType.png.identifier, inItemSet: IndexSet(integersIn: 0..<3)), originals)
        XCTAssertEqual(model.entries.first?.items, entry.items)
    }

    func testMountedRowReloadsRestoredFileAtTheSameURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let filesRoot = root.appendingPathComponent("ClipboardFiles", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        let url = filesRoot.appendingPathComponent("preview.png")
        func imageData(width: Int) -> Data {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: 3), format: format).pngData { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 3))
            }
        }
        try imageData(width: 4).write(to: url)
        let entry = ClipboardEntry(items: [ClipboardPayloadItem(representations: [
            ClipboardRepresentation(type: UTType.fileURL.identifier, data: Data(url.absoluteString.utf8)),
        ])], ownedFiles: [ClipboardOwnedFile(name: "preview.png", relativePath: "preview.png")])
        let store = ClipboardHistoryStore(url: root.appendingPathComponent("clipboard.json"))
        _ = try await store.insert(entry)
        let preferencesName = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: preferencesName))
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let model = IOSClipboardModel(
            rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly), preferences: preferences
        )
        await model.load()
        let host = UIHostingController(rootView: ClipboardItemRow(entry: entry, model: model, onCopy: {}))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let scale = host.traitCollection.displayScale
        func waitForThumbnail(width: Int) async -> Bool {
            await TestReadiness.wait {
                AttachmentThumbnailCache.shared.cachedImage(
                    for: url, size: AttachmentThumbnailCache.tileSize, scale: scale
                )?.width == width
            }
        }
        let initiallyLoaded = await waitForThumbnail(width: 4)
        XCTAssertTrue(initiallyLoaded)
        try FileManager.default.removeItem(at: url)
        try imageData(width: 16).write(to: url)
        await model.load()
        XCTAssertEqual(model.entries.map(\.id), [entry.id])
        let restored = await waitForThumbnail(width: 16)
        XCTAssertTrue(restored, "A mounted row must retry the same URL after its file is restored.")
    }
}

// MARK: - Shared menu and expandable-text transitions

@MainActor
private func mountTransitionWindow<Content: View>(_ content: Content) throws -> UIWindow {
    let host = UIHostingController(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    return window
}

@MainActor
private final class GlassMenuTransitionProbe: ObservableObject {
    @Published var isPresented = false
    var dismissesWhenMounted = false
    var reopensWhenClosingStarts = false
    var dismissesWhenSourceLosesFocus = false
    private(set) var interactiveValues: [Bool] = []
    private(set) var mounts = 0
    private(set) var unmounts = 0
    private(set) var sourceFocusCalls: [Bool] = []

    var isMounted: Bool { mounts > unmounts }
    var isInteractive: Bool { isMounted && interactiveValues.last == true }
    var everInteractive: Bool { interactiveValues.contains(true) }
    /// The source regains focus exactly when its presentation finishes.
    var finishCount: Int { sourceFocusCalls.filter { $0 }.count }

    func recordMount() {
        mounts += 1
        if dismissesWhenMounted {
            dismissesWhenMounted = false
            isPresented = false
        }
    }

    func recordUnmount() { unmounts += 1 }

    func recordInteractive(_ interactive: Bool) {
        let wasInteractive = interactiveValues.last == true
        interactiveValues.append(interactive)
        if wasInteractive, !interactive, reopensWhenClosingStarts {
            reopensWhenClosingStarts = false
            isPresented = true
        }
    }

    func recordSourceFocus(_ focused: Bool) {
        sourceFocusCalls.append(focused)
        if !focused, dismissesWhenSourceLosesFocus {
            dismissesWhenSourceLosesFocus = false
            isPresented = false
        }
    }
}

private struct GlassMenuTransitionView: View {
    @ObservedObject var probe: GlassMenuTransitionProbe

    var body: some View {
        VStack {
            Spacer()
            Color.clear
                .frame(width: 44, height: 44)
                .glassMenu(
                    isPresented: $probe.isPresented, label: "Transition probe",
                    identifier: "transition-probe-menu",
                    sizeProbe: AnyView(Color.clear.frame(width: 200, height: 120)),
                    sourceFocus: { probe.recordSourceFocus($0) }
                ) { isInteractive in
                    GlassMenuTransitionContent(isInteractive: isInteractive, probe: probe)
                }
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassMenuHost()
    }
}

private struct GlassMenuTransitionContent: View {
    let isInteractive: Bool
    let probe: GlassMenuTransitionProbe

    var body: some View {
        Color.clear
            .frame(width: 200, height: 120)
            .onAppear { probe.recordMount() }
            .onDisappear { probe.recordUnmount() }
            .onChange(of: isInteractive, initial: true) { _, interactive in
                probe.recordInteractive(interactive)
            }
    }
}

private struct TransitionTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class ExpandableTextTransitionProbe: ObservableObject {
    nonisolated static let identifier = "expandable-transition-probe"
    nonisolated static func longText(_ name: String) -> String {
        (1...12).map { "\(name) line \($0) of a long snip" }.joined(separator: "\n")
    }

    @Published var content = SnipTextContent.literal(ExpandableTextTransitionProbe.longText("First"))
    private(set) var activations = 0
    private(set) var heights: [CGFloat] = []
    private var replacements = 0

    var height: CGFloat { heights.last ?? 0 }

    func activate() -> Bool {
        activations += 1
        return true
    }

    func record(height: CGFloat) { heights.append(height) }

    func replaceContent() {
        replacements += 1
        content = .literal(Self.longText(["Second", "Third", "Fourth"][(replacements - 1) % 3]))
    }
}

private struct ExpandableTextTransitionView: View {
    @ObservedObject var probe: ExpandableTextTransitionProbe

    var body: some View {
        ExpandableSnipText(
            content: probe.content, lineLimit: 2,
            accessibilityIdentifier: ExpandableTextTransitionProbe.identifier,
            onActivate: { _ in probe.activate() }
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.record(height: $0) }
        .frame(width: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// SwiftUI builds its iOS accessibility tree only while an assistive client is active, which a
/// unit-test host lacks. UI-driving and snapshot tools turn on application accessibility
/// through these libAccessibility switches; the tests do the same for one test at a time.
@MainActor
private enum ApplicationAccessibility {
    private typealias Read = @convention(c) () -> Int32
    private typealias Write = @convention(c) (Int32) -> Void
    private static let libraryPath = "/usr/lib/libAccessibility.dylib"
    private static let switches = [
        (read: "_AXSApplicationAccessibilityEnabled", write: "_AXSApplicationAccessibilitySetEnabled", required: true),
        (read: "_AXSAutomationEnabled", write: "_AXSSetAutomationEnabled", required: false),
    ]

    static var isEnabled: Bool {
        guard let library = openLibrary(), let read: Read = symbol(switches[0].read, in: library) else { return false }
        return read() != 0
    }

    /// Turns the switches on and restores their previous values when `test` tears down.
    static func enable(for test: XCTestCase) throws {
        guard let library = openLibrary() else {
            throw TransitionTestFailure(description:
                "\(libraryPath) did not load (\(dlerror().map { String(cString: $0) } ?? "no dlerror")), "
                    + "so SwiftUI cannot expose its accessibility tree."
            )
        }
        var previous: [(write: String, value: Int32)] = []
        for flag in switches {
            guard let read: Read = symbol(flag.read, in: library),
                  let write: Write = symbol(flag.write, in: library) else {
                if flag.required {
                    throw TransitionTestFailure(description:
                        "\(libraryPath) has no \(flag.read) or \(flag.write), so application accessibility cannot be enabled."
                    )
                }
                continue
            }
            previous.append((write: flag.write, value: read()))
            write(1)
        }
        let restore = previous
        test.addTeardownBlock {
            await MainActor.run {
                guard let library = ApplicationAccessibility.openLibrary() else { return }
                for flag in restore {
                    if let write: Write = ApplicationAccessibility.symbol(flag.write, in: library) { write(flag.value) }
                }
            }
        }
    }

    private static func openLibrary() -> UnsafeMutableRawPointer? {
        let simulatorPath = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"].map { $0 + libraryPath }
        for path in [simulatorPath, libraryPath].compactMap({ $0 }) {
            if let library = dlopen(path, RTLD_NOW) { return library }
        }
        return nil
    }

    private static func symbol<Function>(_ name: String, in library: UnsafeMutableRawPointer) -> Function? {
        guard let address = dlsym(library, name) else { return nil }
        return unsafeBitCast(address, to: Function.self)
    }
}

@MainActor
private func renderedPixels(of view: UIView) -> [UInt8] {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
        _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    guard let data = image.cgImage?.dataProvider?.data else { return [] }
    return [UInt8](data as Data)
}

@MainActor
private struct HostedExpandableText {
    struct Interruption {
        let height: CGFloat
        let attempt: Int
    }

    private static let attempts = 3

    let probe: ExpandableTextTransitionProbe
    let window: UIWindow
    let hostView: UIView
    let collapsedHeight: CGFloat
    let collapsedRender: [UInt8]
    var fullHeight: CGFloat = 0

    /// Mounts the row, then expands and collapses it once to measure the full height and to
    /// check that a collapsed row renders the truncated preview again.
    static func mount(for test: XCTestCase) async throws -> HostedExpandableText {
        // With Reduce Motion on, the text toggles without animation and never reports a mid-animation height.
        guard !UIAccessibility.isReduceMotionEnabled else {
            throw TransitionTestFailure(description:
                "Reduce Motion is on, so the text toggles without animation; turn it off to run these tests."
            )
        }
        try ApplicationAccessibility.enable(for: test)
        // UIKit loads its accessibility support after the switch flips; mount the row afterward.
        try await Task.sleep(for: .milliseconds(300))
        let probe = ExpandableTextTransitionProbe()
        let window = try mountTransitionWindow(ExpandableTextTransitionView(probe: probe))
        let hostView = try XCTUnwrap(window.rootViewController?.view)
        let exposed = await TestReadiness.wait {
            hostView.layoutIfNeeded()
            return findButton(in: window, label: probe.content.accessibilityText) != nil && probe.height > 0
        }
        XCTAssertTrue(exposed, """
            The hosted expandable text should expose its accessibility button \
            (application accessibility on: \(ApplicationAccessibility.isEnabled), \
            host elements: \(hostView.accessibilityElements?.count ?? hostView.accessibilityElementCount())).
            """)
        try await Task.sleep(for: .milliseconds(300))
        // A clipped full text would drop this ellipsis, so the render comparison can see it.
        XCTAssertTrue(String(probe.content.presentation(lineLimit: 2).preview.characters).hasSuffix("…"))

        var text = HostedExpandableText(
            probe: probe, window: window, hostView: hostView,
            collapsedHeight: probe.height, collapsedRender: renderedPixels(of: hostView)
        )
        XCTAssertFalse(text.collapsedRender.isEmpty)
        try await text.activate()
        let expanded = await TestReadiness.wait {
            text.value == "Expanded" && probe.height > text.collapsedHeight * 2
        }
        XCTAssertTrue(expanded, "The row should expand on its own before the interruption tests.")
        try await Task.sleep(for: .milliseconds(400))
        text.fullHeight = probe.height
        XCTAssertNotEqual(
            renderedPixels(of: hostView), text.collapsedRender,
            "Rendering must capture the row's text, or the collapsed-render check proves nothing."
        )
        try await text.activate()
        let collapsed = await TestReadiness.wait { text.isCollapsed }
        XCTAssertTrue(collapsed, "The row should collapse on its own before the interruption tests.")
        let restored = await TestReadiness.wait { text.rendersCollapsedPreview }
        XCTAssertTrue(restored, "A collapsed row should render its truncated preview again.")
        return text
    }

    private static func findButton(in window: UIWindow, label: String) -> NSObject? {
        accessibilityButton(identifier: ExpandableTextTransitionProbe.identifier, label: label, in: window, depth: 0)
    }

    // SwiftUI exposes its nodes through the informal UIAccessibility container API.
    private static func accessibilityButton(
        identifier: String, label: String, in element: NSObject, depth: Int
    ) -> NSObject? {
        if (element as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier
            || (element.accessibilityLabel == label && element.accessibilityTraits.contains(.button)) {
            return element
        }
        guard depth < 48 else { return nil }
        var children = element.accessibilityElements ?? []
        if children.isEmpty {
            let count = element.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                children = (0..<count).compactMap { element.accessibilityElement(at: $0) }
            }
        }
        if let view = element as? UIView {
            children.append(contentsOf: view.subviews.map { $0 as Any })
        }
        for case let child as NSObject in children {
            if let match = accessibilityButton(identifier: identifier, label: label, in: child, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    private var button: NSObject? { Self.findButton(in: window, label: probe.content.accessibilityText) }

    /// Activates the row and returns once its `onActivate` ran.
    func activate() async throws {
        let previous = probe.activations
        let button = try XCTUnwrap(self.button, "The expandable text left the accessibility tree.")
        _ = button.accessibilityActivate()
        guard await TestReadiness.wait(until: { probe.activations > previous }) else {
            throw TransitionTestFailure(description: "The accessibility activation did not reach the text's onActivate.")
        }
    }

    /// Presses the row and runs `interrupt` on the first reported height strictly between
    /// `start` and `end`, which only occurs while the reveal animates. If the press reaches
    /// `end` without such a frame, `interrupt` still runs, the row settles, and another attempt
    /// starts. When no attempt lands mid-animation, this throws.
    func pressAndInterrupt(
        from start: CGFloat, to end: CGFloat, settled: () -> Bool,
        with interrupt: () async throws -> Void
    ) async throws -> Interruption {
        let low = min(start, end) + 2
        let high = max(start, end) - 2
        var missedHeights: [[CGFloat]] = []
        for attempt in 1...Self.attempts {
            let firstReading = probe.heights.count
            try await activate()
            var interruptedAt: CGFloat?
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                let height = probe.height
                if height > low, height < high {
                    interruptedAt = height
                    break
                }
                if probe.heights.count > firstReading, abs(height - end) <= 1 { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            // Acting right after the check, with no suspension between, keeps the frame current.
            try await interrupt()
            if let interruptedAt { return Interruption(height: interruptedAt, attempt: attempt) }
            missedHeights.append(Array(probe.heights[firstReading...]))
            let didSettle = await TestReadiness.wait { settled() }
            XCTAssertTrue(didSettle, "The row should settle before the next interruption attempt.")
            try await Task.sleep(for: .milliseconds(400))
        }
        throw TransitionTestFailure(description:
            "No reported height fell strictly between \(start) and \(end) in \(Self.attempts) attempts "
                + "(heights per attempt: \(missedHeights)). The runner may report only end-state geometry."
        )
    }

    var value: String? { button?.accessibilityValue }

    var isCollapsed: Bool {
        value == "Collapsed" && abs(probe.height - collapsedHeight) <= 1
    }

    var isExpanded: Bool {
        value == "Expanded" && abs(probe.height - fullHeight) <= 1
    }

    /// Clipped full text has the same height and value, but its second line lacks the ellipsis.
    var rendersCollapsedPreview: Bool {
        renderedPixels(of: hostView) == collapsedRender
    }
}

@MainActor
final class SharedTransitionHostTests: XCTestCase {
    private let settleTime: Duration = .milliseconds(500)

    func testGlassMenuOpensInteractiveThenClosesAndFinishesOnce() async throws {
        let probe = GlassMenuTransitionProbe()
        let window = try mountTransitionWindow(GlassMenuTransitionView(probe: probe))
        defer { window.isHidden = true }

        probe.isPresented = true
        let opened = await TestReadiness.wait { probe.isInteractive }
        XCTAssertTrue(opened, "The menu should become interactive once it opens.")
        XCTAssertEqual(probe.finishCount, 0)

        probe.isPresented = false
        let closed = await TestReadiness.wait { !probe.isMounted && probe.finishCount > 0 }
        XCTAssertTrue(closed, "The menu should unmount and finish after it closes.")
        try await Task.sleep(for: settleTime)
        XCTAssertFalse(probe.isMounted)
        XCTAssertEqual(probe.interactiveValues.last, false)
        XCTAssertEqual(probe.finishCount, 1)
    }

    func testGlassMenuClosedWhileOpeningNeverBecomesInteractive() async throws {
        let probe = GlassMenuTransitionProbe()
        let window = try mountTransitionWindow(GlassMenuTransitionView(probe: probe))
        defer { window.isHidden = true }

        probe.dismissesWhenMounted = true
        probe.isPresented = true
        let closed = await TestReadiness.wait { probe.mounts > 0 && !probe.isMounted && probe.finishCount > 0 }
        XCTAssertTrue(closed, "A menu closed while opening should unmount and finish.")
        try await Task.sleep(for: settleTime)
        XCTAssertFalse(probe.isPresented)
        XCTAssertFalse(probe.isMounted)
        XCTAssertFalse(probe.everInteractive, "A menu closed while opening must not become interactive.")
        XCTAssertEqual(probe.finishCount, 1)
    }

    func testGlassMenuReopenedWhileClosingEndsOpenWithoutFinishing() async throws {
        let probe = GlassMenuTransitionProbe()
        let window = try mountTransitionWindow(GlassMenuTransitionView(probe: probe))
        defer { window.isHidden = true }

        probe.isPresented = true
        let opened = await TestReadiness.wait { probe.isInteractive }
        XCTAssertTrue(opened)

        probe.reopensWhenClosingStarts = true
        probe.isPresented = false
        let reopened = await TestReadiness.wait { !probe.reopensWhenClosingStarts && probe.isInteractive }
        XCTAssertTrue(reopened, "A menu reopened while closing should end open and interactive.")
        try await Task.sleep(for: settleTime)
        XCTAssertTrue(probe.isPresented)
        XCTAssertTrue(probe.isInteractive)
        XCTAssertEqual(probe.finishCount, 0, "The interrupted close must not finish the presentation.")
    }

    func testGlassMenuRapidTogglesEndClosed() async throws {
        let probe = GlassMenuTransitionProbe()
        let window = try mountTransitionWindow(GlassMenuTransitionView(probe: probe))
        defer { window.isHidden = true }

        for presented in [true, false, true, false] {
            probe.isPresented = presented
            try await Task.sleep(for: .milliseconds(20))
        }
        let closed = await TestReadiness.wait { !probe.isMounted && probe.finishCount > 0 }
        XCTAssertTrue(closed, "The last request was a close, so the menu should end closed.")
        let finishes = probe.finishCount
        try await Task.sleep(for: settleTime)
        XCTAssertFalse(probe.isPresented)
        XCTAssertFalse(probe.isMounted)
        XCTAssertFalse(probe.isInteractive)
        XCTAssertEqual(probe.finishCount, finishes, "Stale completions must not finish again.")
    }

    func testGlassMenuDismissedAsItStartsPresentingStillFinishes() async throws {
        let probe = GlassMenuTransitionProbe()
        let window = try mountTransitionWindow(GlassMenuTransitionView(probe: probe))
        defer { window.isHidden = true }

        // The source hands focus away in the same update that claims the host.
        // Dismissing there lands before the surface ever sees the presentation.
        probe.dismissesWhenSourceLosesFocus = true
        probe.isPresented = true
        let finished = await TestReadiness.wait { probe.finishCount > 0 }
        XCTAssertTrue(finished, "A dismissed presentation must release the host and return source focus.")
        try await Task.sleep(for: settleTime)
        XCTAssertFalse(probe.isPresented)
        XCTAssertFalse(probe.isMounted)
        XCTAssertFalse(probe.everInteractive)
        XCTAssertEqual(probe.finishCount, 1)
    }

    func testExpandableTextCollapsedDuringExpansionSettlesCollapsed() async throws {
        let text = try await HostedExpandableText.mount(for: self)
        defer { text.window.isHidden = true }
        let activations = text.probe.activations

        let interruption = try await text.pressAndInterrupt(
            from: text.collapsedHeight, to: text.fullHeight, settled: { text.isCollapsed }
        ) {
            try await text.activate()
        }
        XCTAssertGreaterThan(interruption.height, text.collapsedHeight + 2, "The collapse must land mid-expansion.")
        XCTAssertLessThan(interruption.height, text.fullHeight - 2, "The collapse must land mid-expansion.")

        let collapsed = await TestReadiness.wait { text.isCollapsed }
        XCTAssertTrue(collapsed, "Collapsing mid-expansion should settle collapsed.")
        try await Task.sleep(for: settleTime)
        XCTAssertTrue(text.isCollapsed)
        let restored = await TestReadiness.wait { text.rendersCollapsedPreview }
        XCTAssertTrue(restored, "The collapsed row must show its truncated preview, not clipped full text.")
        XCTAssertEqual(text.probe.activations, activations + 2 * interruption.attempt)
    }

    func testExpandableTextExpandedDuringCollapseSettlesExpanded() async throws {
        let text = try await HostedExpandableText.mount(for: self)
        defer { text.window.isHidden = true }
        try await text.activate()
        let expanded = await TestReadiness.wait { text.isExpanded }
        XCTAssertTrue(expanded)
        try await Task.sleep(for: settleTime)
        let activations = text.probe.activations

        let interruption = try await text.pressAndInterrupt(
            from: text.fullHeight, to: text.collapsedHeight, settled: { text.isExpanded }
        ) {
            try await text.activate()
        }
        XCTAssertGreaterThan(interruption.height, text.collapsedHeight + 2, "The expansion must land mid-collapse.")
        XCTAssertLessThan(interruption.height, text.fullHeight - 2, "The expansion must land mid-collapse.")

        let reexpanded = await TestReadiness.wait { text.isExpanded }
        XCTAssertTrue(reexpanded, "Expanding mid-collapse should settle at the full height.")
        try await Task.sleep(for: settleTime)
        XCTAssertTrue(text.isExpanded)
        XCTAssertEqual(text.probe.activations, activations + 2 * interruption.attempt)
    }

    func testExpandableTextContentChangeDuringExpansionResetsCollapsed() async throws {
        let text = try await HostedExpandableText.mount(for: self)
        defer { text.window.isHidden = true }
        let activations = text.probe.activations

        let interruption = try await text.pressAndInterrupt(
            from: text.collapsedHeight, to: text.fullHeight, settled: { text.isCollapsed }
        ) {
            text.probe.replaceContent()
        }
        XCTAssertGreaterThan(interruption.height, text.collapsedHeight + 2, "The new content must land mid-expansion.")
        XCTAssertLessThan(interruption.height, text.fullHeight - 2, "The new content must land mid-expansion.")

        let collapsed = await TestReadiness.wait { text.isCollapsed }
        XCTAssertTrue(collapsed, "New content should reset the text to collapsed.")
        try await Task.sleep(for: settleTime)
        XCTAssertTrue(text.isCollapsed)
        XCTAssertEqual(text.probe.activations, activations + interruption.attempt)
    }
}
