import SnipSnapCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnapiOS

/// Opening or closing an iPhone Duo, or resizing iPad Split View, swaps the compact and regular
/// library trees. These tests host the real root view and swap its size class.
@MainActor
final class IOSFoldContinuityTests: IOSModelTestCase {
    func testDraftTextAndAttachmentSurviveSizeClassSwaps() throws {
        let storage = makeComposerStorage()
        let attachment = storage.stagingDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("fold-attachment.txt")
        try FileManager.default.createDirectory(
            at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("attached".utf8).write(to: attachment)
        storage.draftStore.setText("Fold draft", for: SnipList.inboxID)
        storage.draftStore.addTemporary(attachment, to: SnipList.inboxID)
        let root = try RootHarness(test: self, storage: storage)

        for sizeClass in [UIUserInterfaceSizeClass.compact, .regular, .compact, .regular] {
            root.swap(to: sizeClass)
            // This harness can't see SwiftUI's attachment strip. The text stands in for the whole
            // draft, which the new composer loads from the same store as its attachments.
            let shown = root.wait("\(sizeClass) composer shows the draft") { root.composer?.text == "Fold draft" }
            XCTAssertTrue(shown, root.diagnostics)
            XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID).attachments, [attachment])
            XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path), "\(sizeClass)")
        }
    }

    func testAttachmentStagingFinishesAcrossSizeClassSwap() throws {
        let storage = makeComposerStorage()
        storage.draftStore.setText("before ", for: SnipList.inboxID)
        let root = try RootHarness(test: self, storage: storage)
        XCTAssertTrue(root.wait("compact composer") { root.composer?.text == "before " }, root.diagnostics)
        let compact = try XCTUnwrap(root.composer)
        compact.selectedRange = NSRange(location: 7, length: 0)

        let started = expectation(description: "Text provider started")
        let release = DispatchSemaphore(value: 0)
        let text = NSItemProvider()
        text.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            started.fulfill()
            DispatchQueue.global().async {
                release.wait()
                completion(Data("hello".utf8), nil)
            }
            return Progress(totalUnitCount: 1)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        compact.paste(itemProviders: [text, NSItemProvider(object: image)])
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: TestReadiness.timeout), .completed)

        root.swap(to: .regular)
        release.signal()
        let staged = root.wait("the staged paste reaches the regular composer") {
            root.composer !== compact && root.composer?.text == "before hello"
                && storage.draftStore.draft(for: SnipList.inboxID).attachments.count == 1
        }
        XCTAssertTrue(staged, root.diagnostics)
        let file = try XCTUnwrap(storage.draftStore.draft(for: SnipList.inboxID).attachments.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testSelectedPageSearchAndGatheredSnipsSurviveSizeClassSwaps() async throws {
        let root = try RootHarness(test: self, storage: makeComposerStorage())
        let model = root.session.model
        XCTAssertTrue(root.wait("compact library shown") { root.composer != nil }, root.diagnostics)
        for content in ["Gather me", "Leave me"] {
            let created = await model.createSnip(content: content, in: SnipList.inboxID)
            XCTAssertTrue(created)
        }
        let first = try XCTUnwrap(model.snips.first { $0.content == "Gather me" })
        let created = await model.createList(name: "Fold")
        XCTAssertTrue(created)
        let list = try XCTUnwrap(model.lists.first { $0.name == "Fold" })
        model.selectList(SnipList.inboxID)
        model.selectSnips([first.id])

        for sizeClass in [UIUserInterfaceSizeClass.regular, .compact] {
            root.swap(to: sizeClass)
            root.settle()
            XCTAssertTrue(model.isSelectingSnips, "\(sizeClass)")
            XCTAssertEqual(model.selectedSnipIDs, [first.id], "\(sizeClass)")
        }
        model.endSelectingSnips()

        model.selectList(list.id)
        // Changing pages closes search, so open it once the page change has been handled.
        root.settle()
        model.isSearchPresented = true
        model.searchText = "Gather"
        for sizeClass in [UIUserInterfaceSizeClass.regular, .compact, .regular] {
            root.swap(to: sizeClass)
            // The regular layout's search field is not in this harness's view tree; the Duo UI test checks it.
            if sizeClass == .compact {
                let presented = root.wait("compact search field shows the query") { root.visibleSearchFieldTexts.contains("Gather") }
                XCTAssertTrue(presented, root.searchFieldDiagnostics)
            }
            root.settle()
            XCTAssertTrue(model.isSearchPresented, "\(sizeClass)")
            XCTAssertEqual(model.searchText, "Gather", "\(sizeClass)")
            XCTAssertEqual(model.selectedPage, .list(list.id), "\(sizeClass)")
        }
    }

    func testPageMotionInterruptedByTreeSwapIgnoresLateGestureEnds() {
        let pages: [LibraryPage] = [.clipboard, .list(SnipList.inboxID), .list(UUID())]
        func dragging() -> ListPageMotion {
            var motion = ListPageMotion()
            motion.updatePageDrag(
                translation: CGSize(width: -120, height: 0), selectedPage: pages[1], pages: pages,
                pageWidth: 400, layoutDirection: .leftToRight, isStart: true, at: Date()
            )
            XCTAssertTrue(motion.isDragging)
            motion.interrupt()
            return motion
        }
        var cancelled = dragging()
        cancelled.cancelPageDrag(reduceMotion: false, at: Date())
        XCTAssertNil(cancelled.transition)

        var ended = dragging()
        XCTAssertNil(ended.releasePageDrag(
            translation: CGSize(width: -300, height: 0), predictedEndTranslation: CGSize(width: -400, height: 0),
            reduceMotion: false, at: Date()
        ))
        XCTAssertNil(ended.transition, "A late release must not select a page or start a settlement")

        let geometry = ListSelectorGeometry(widths: [90, 110, 90])
        var selector = ListPageMotion()
        selector.updateDrag(
            translation: CGSize(width: -60, height: 0), selectedPage: pages[1], pages: pages,
            geometry: geometry, layoutDirection: .leftToRight, at: Date()
        )
        XCTAssertTrue(selector.isSelectorDragging)
        selector.interrupt()
        XCTAssertNil(selector.release(
            translation: CGSize(width: -120, height: 0), geometry: geometry, reduceMotion: false, at: Date()
        ))
        selector.cancelDrag(reduceMotion: false, at: Date())
        XCTAssertNil(selector.transition)
    }

    func testComposerClearsFocusWhenTheSystemRefusesIt() throws {
        var focused = false
        let blocker = FocusKeepingTextField()
        let host = UIHostingController(rootView: ComposerTextInput(
            prompt: "Add", text: .constant("Draft"),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            onPasteAttachments: { _, _ in }
        ))
        let window = try makeWindow(host)
        defer { window.isHidden = true }
        host.view.addSubview(blocker)
        XCTAssertTrue(blocker.becomeFirstResponder())

        focused = true
        host.rootView = ComposerTextInput(
            prompt: "Add", text: .constant("Draft"),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            onPasteAttachments: { _, _ in }
        )
        host.view.layoutIfNeeded()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !focused }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: TestReadiness.timeout), .completed)
        XCTAssertTrue(blocker.isFirstResponder)
    }

    private func makeComposerStorage() -> CompactComposerStorage {
        let suite = "fold-continuity-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return CompactComposerStorage(defaults: defaults)
    }
}

private final class FocusKeepingTextField: UITextField {
    override var canResignFirstResponder: Bool { false }
}

@MainActor
private func makeWindow(_ host: UIViewController) throws -> UIWindow {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    return window
}

@MainActor
private final class RootHarness {
    let session: IOSAppSession
    private let host: UIHostingController<IOSAppRootView>
    private let window: UIWindow

    init(test: XCTestCase, storage: CompactComposerStorage, library: ModelTestLibrary = ModelTestLibrary()) throws {
        session = IOSAppSession(library: library)
        host = UIHostingController(rootView: IOSAppRootView(session: session, composerStorage: storage))
        host.traitOverrides.horizontalSizeClass = .compact
        window = try makeWindow(host)
        test.addTeardownBlock { [window] in await MainActor.run { window.isHidden = true } }
    }

    func swap(to sizeClass: UIUserInterfaceSizeClass) {
        host.traitOverrides.horizontalSizeClass = sizeClass
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertTrue(wait("\(sizeClass) tree mounted") { self.isRegular == (sizeClass == .regular) })
    }

    /// Gives teardown callbacks, deferred focus, and presentation updates time to run.
    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(1))
    }

    func wait(_ description: String, until condition: @escaping () -> Bool) -> Bool {
        let met = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { condition() }
        }, object: nil)
        met.expectationDescription = description
        return XCTWaiter.wait(for: [met], timeout: TestReadiness.timeout) == .completed
    }

    var diagnostics: String {
        var composers: [String] = []
        func collect(_ view: UIView) {
            if let input = view as? ComposerTextView {
                composers.append("text=\(input.text ?? "nil") window=\(input.window != nil) hidden=\(input.isHidden) frame=\(input.frame)")
            }
            view.subviews.forEach(collect)
        }
        collect(window)
        return "regular=\(isRegular) composers=\(composers) windowFrame=\(window.frame)"
    }

    var isRegular: Bool { first(UISplitViewController.self, in: host) != nil }

    var composer: ComposerTextView? { firstView(ComposerTextView.self) }

    var visibleSearchFieldTexts: [String] {
        allViews(UISearchTextField.self).filter { $0.window != nil && !$0.isHidden && $0.alpha > 0 }.map { $0.text ?? "" }
    }

    var searchFieldDiagnostics: String {
        allViews(UISearchTextField.self).map {
            "text=\($0.text ?? "nil") window=\($0.window != nil) hidden=\($0.isHidden) alpha=\($0.alpha) frame=\($0.convert($0.bounds, to: nil)) first=\($0.isFirstResponder)"
        }.joined(separator: "; ")
    }

    private func allViews<View: UIView>(_ type: View.Type) -> [View] {
        func search(_ view: UIView) -> [View] {
            (view as? View).map { [$0] } ?? [] + view.subviews.flatMap(search)
        }
        return search(window)
    }

    private func first<Controller: UIViewController>(_ type: Controller.Type, in controller: UIViewController) -> Controller? {
        if let match = controller as? Controller, match.viewIfLoaded?.window != nil { return match }
        return controller.children.lazy.compactMap { self.first(type, in: $0) }.first
    }

    private func firstView<View: UIView>(_ type: View.Type) -> View? {
        func search(_ view: UIView) -> View? {
            if let match = view as? View, match.window != nil, !match.isHidden { return match }
            return view.subviews.lazy.compactMap(search).first
        }
        return search(window)
    }
}
