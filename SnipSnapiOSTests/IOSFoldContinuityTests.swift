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
        let attachment = try addInboxDraft("Fold draft", to: storage)
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

    func testFailedSaveShowsItsDraftInTheComposerMountedDuringIt() async throws {
        let storage = makeComposerStorage()
        let attachment = try addInboxDraft("Unsent", to: storage)
        let root = try RootHarness(test: self, storage: storage)
        let gate = SaveGate()
        let saving = try await startSaveAndSwap(storage, root: root, gate: gate)
        XCTAssertEqual(gate.draft?.attachments, [attachment])

        gate.finish(saved: false)
        let saved = await saving.value
        XCTAssertFalse(saved)
        let restored = await TestReadiness.wait {
            root.composer?.text == "Unsent" && root.composer?.isEditable == true
        }
        XCTAssertTrue(restored, "The regular composer must show the unsent draft. \(root.diagnostics)")
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID).attachments, [attachment])
    }

    func testSavedDraftStaysOutOfTheComposerMountedDuringTheSave() async throws {
        let storage = makeComposerStorage()
        _ = try addInboxDraft("Sent", to: storage)
        let root = try RootHarness(test: self, storage: storage)
        let gate = SaveGate()
        let saving = try await startSaveAndSwap(storage, root: root, gate: gate)

        gate.finish(saved: true)
        let saved = await saving.value
        XCTAssertTrue(saved)
        let ended = await TestReadiness.wait { root.composer?.isEditable == true }
        XCTAssertTrue(ended, "The regular composer must accept typing again. \(root.diagnostics)")
        // Suspends rather than spinning the run loop, so a wrong reload queued on the main actor would run.
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(root.composer?.text, "", root.diagnostics)
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID), ComposerDraft())
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

    /// Holds a save of the Inbox draft in `gate` while the compact composer is replaced by a regular one.
    private func startSaveAndSwap(
        _ storage: CompactComposerStorage, root: RootHarness, gate: SaveGate
    ) async throws -> Task<Bool, Never> {
        let draft = storage.draftStore.draft(for: SnipList.inboxID).text
        XCTAssertTrue(root.wait("compact composer") { root.composer?.text == draft }, root.diagnostics)
        let compact = try XCTUnwrap(root.composer)
        let saving = Task { await storage.save(listID: SnipList.inboxID, create: gate.create) }
        // The save runs on the main actor, so the test must suspend, not spin the run loop, to let it start.
        let started = await TestReadiness.wait { gate.draft != nil }
        XCTAssertTrue(started, "The save must start and wait in the gate.")
        XCTAssertEqual(gate.draft?.text, draft)
        root.swap(to: .regular)
        let mounted = root.wait("regular composer mounted mid-save") {
            root.composer !== compact && root.composer?.text == "" && root.composer?.isEditable == false
        }
        XCTAssertTrue(mounted, root.diagnostics)
        return saving
    }

    /// Returns the draft's attachment, a staged file.
    private func addInboxDraft(_ text: String, to storage: CompactComposerStorage) throws -> URL {
        let attachment = storage.stagingDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("fold-attachment.txt")
        try FileManager.default.createDirectory(
            at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("attached".utf8).write(to: attachment)
        storage.draftStore.setText(text, for: SnipList.inboxID)
        storage.draftStore.addTemporary(attachment, to: SnipList.inboxID)
        return attachment
    }

    private func makeComposerStorage() -> CompactComposerStorage {
        let suite = "fold-continuity-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return CompactComposerStorage(defaults: defaults)
    }
}

/// Stands in for creating the snip, and holds the save until the test finishes it.
@MainActor
private final class SaveGate {
    private(set) var draft: ComposerDraft?
    private var outcome: Bool?
    private var result: CheckedContinuation<Bool, Never>?

    func create(_ draft: ComposerDraft) async -> Bool {
        self.draft = draft
        if let outcome { return outcome }
        return await withCheckedContinuation { result = $0 }
    }

    /// Also answers a save that starts late, so a failed wait can't leave the test hanging.
    func finish(saved: Bool) {
        outcome = saved
        result?.resume(returning: saved)
        result = nil
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
        let composers = allViews(ComposerTextView.self).map {
            "text=\($0.text ?? "nil") window=\($0.window != nil) hidden=\($0.isHidden) frame=\($0.frame)"
        }
        return "regular=\(isRegular) composers=\(composers) windowFrame=\(window.frame)"
    }

    var isRegular: Bool { first(UISplitViewController.self, in: host) != nil }

    var composer: ComposerTextView? {
        allViews(ComposerTextView.self).first { $0.window != nil && !$0.isHidden }
    }

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
            ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap(search)
        }
        return search(window)
    }

    private func first<Controller: UIViewController>(_ type: Controller.Type, in controller: UIViewController) -> Controller? {
        if let match = controller as? Controller, match.viewIfLoaded?.window != nil { return match }
        return controller.children.lazy.compactMap { self.first(type, in: $0) }.first
    }
}
