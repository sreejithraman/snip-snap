import QuickLook
import SnipSnapCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnapiOS

/// Opening or closing an iPhone Duo, or resizing iPad Split View, swaps the compact and regular
/// library trees. These tests host the real root view and swap its size class. They run against
/// the rail here and against the sidebar in `IOSFoldContinuitySidebarTests`.
@MainActor
class IOSFoldContinuityTests: IOSModelTestCase {
    class var regularLayout: RegularLibraryLayout { .rail }

    func testDraftTextAndAttachmentSurviveSizeClassSwaps() async throws {
        let storage = makeComposerStorage()
        let attachment = try addInboxDraft("Fold draft", to: storage)
        let root = try RootHarness(test: self, storage: storage)

        for sizeClass in [UIUserInterfaceSizeClass.compact, .regular, .compact, .regular] {
            await root.swap(to: sizeClass)
            // This harness can't see SwiftUI's attachment strip. The text stands in for the whole
            // draft, which the new composer loads from the same store as its attachments.
            await root.expect("\(sizeClass) composer shows the draft") { root.composer?.text == "Fold draft" }
            XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID).attachments, [attachment])
            XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path), "\(sizeClass)")
        }
    }

    func testAttachmentStagingFinishesAcrossSizeClassSwap() async throws {
        let storage = makeComposerStorage()
        storage.draftStore.setText("before ", for: SnipList.inboxID)
        let root = try RootHarness(test: self, storage: storage)
        await root.expect("compact composer") { root.composer?.text == "before " }
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
        await fulfillment(of: [started], timeout: TestReadiness.timeout)

        await root.swap(to: .regular)
        release.signal()
        await root.expect("the staged paste reaches the regular composer") {
            root.composer !== compact && root.composer?.text == "before hello"
                && storage.draftStore.draft(for: SnipList.inboxID).attachments.count == 1
        }
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

    func testOverlappingSaveLeavesTheRunningSaveBusy() async throws {
        let storage = makeComposerStorage()
        let attachment = try addInboxDraft("In flight", to: storage)
        let root = try RootHarness(test: self, storage: storage)
        let gate = SaveGate()
        let saving = try await startSaveAndSwap(storage, root: root, gate: gate)

        for listID in [SnipList.inboxID, UUID()] {
            var created = false
            let saved = await storage.save(listID: listID) { _ in
                created = true
                return true
            }
            XCTAssertFalse(saved, "\(listID)")
            XCTAssertFalse(created, "An overlapping save must not create a snip. \(listID)")
            XCTAssertTrue(storage.isSaving, "\(listID)")
            XCTAssertEqual(storage.savingListID, SnipList.inboxID, "\(listID)")
        }
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID).text, "In flight")
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID).attachments, [attachment])
        // Suspends rather than spinning the run loop, so a wrong reload queued on the main actor would run.
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(root.composer?.text, "", "The in-flight draft must stay out of the composer. \(root.diagnostics)")
        XCTAssertEqual(root.composer?.isEditable, false, "The composer must stay busy. \(root.diagnostics)")

        gate.finish(saved: true)
        let saved = await saving.value
        XCTAssertTrue(saved)
        XCTAssertFalse(storage.isSaving)
        XCTAssertNil(storage.savingListID)
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID), ComposerDraft())
    }

    func testSelectedPageSearchAndGatheredSnipsSurviveSizeClassSwaps() async throws {
        let root = try RootHarness(test: self, storage: makeComposerStorage())
        let model = root.session.model
        await root.expect("compact library shown") { root.composer != nil }
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
            await root.swap(to: sizeClass)
            await root.settle()
            XCTAssertTrue(model.isSelectingSnips, "\(sizeClass)")
            XCTAssertEqual(model.selectedSnipIDs, [first.id], "\(sizeClass)")
        }
        model.endSelectingSnips()

        model.selectList(list.id)
        // Changing pages closes search, so open it once the page change has been handled.
        await root.settle()
        model.isSearchPresented = true
        model.searchText = "Gather"
        for sizeClass in [UIUserInterfaceSizeClass.regular, .compact, .regular] {
            await root.swap(to: sizeClass)
            // This harness checks only the compact search field; the Duo UI test checks the regular layouts'.
            if sizeClass == .compact {
                await root.expect("compact search field shows the query", details: root.searchFieldDiagnostics) {
                    root.visibleSearchFieldTexts.contains("Gather")
                }
            }
            await root.settle()
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
        window.addSubview(blocker)
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

    func testFilesPickerStaysPresentedAcrossSizeClassSwaps() async throws {
        let storage = makeComposerStorage()
        let root = try RootHarness(test: self, storage: storage)
        await root.expect("compact composer") { root.composer != nil }
        let request = ComposerAttachmentPickerRequest(source: .files, listID: SnipList.inboxID)
        storage.presentAttachmentPicker(request)
        await root.expect("Files picker presented") { root.presented(UIDocumentPickerViewController.self) != nil }
        let picker = try XCTUnwrap(root.presented(UIDocumentPickerViewController.self))

        for sizeClass in [UIUserInterfaceSizeClass.regular, .compact] {
            await root.swap(to: sizeClass)
            await root.settle()
            XCTAssertEqual(storage.attachmentPicker, request, "\(sizeClass)")
            XCTAssertTrue(root.presented(UIDocumentPickerViewController.self) === picker, "\(sizeClass)")
        }
        storage.dismissAttachmentPicker()
        await root.expect("Files picker dismissed") { root.presented(UIDocumentPickerViewController.self) == nil }
    }

    func testAttachmentPreviewStaysPresentedAcrossSizeClassSwaps() async throws {
        let storage = makeComposerStorage()
        let attachment = try addInboxDraft("Preview draft", to: storage)
        let root = try RootHarness(test: self, storage: storage)
        await root.expect("compact composer") { root.composer?.text == "Preview draft" }
        // A text file opens in Quick Look; images open the full-screen viewer from the same modifier.
        let request = ComposerAttachmentPreviewRequest(url: attachment, listID: SnipList.inboxID)
        storage.presentAttachmentPreview(request)
        await root.expect("Quick Look presented") { root.presented(QLPreviewController.self) != nil }
        let preview = try XCTUnwrap(root.presented(QLPreviewController.self))

        for sizeClass in [UIUserInterfaceSizeClass.regular, .compact] {
            await root.swap(to: sizeClass)
            await root.settle()
            XCTAssertEqual(storage.attachmentPreview, request, "\(sizeClass)")
            XCTAssertTrue(root.presented(QLPreviewController.self) === preview, "\(sizeClass)")
        }
        storage.dismissAttachmentPreview()
        await root.expect("Quick Look dismissed") { root.presented(QLPreviewController.self) == nil }
    }

    func testPickedFileStagesIntoTheListThatOpenedThePicker() async throws {
        let storage = makeComposerStorage()
        storage.draftStore.setText("Picked for Inbox", for: SnipList.inboxID)
        let root = try RootHarness(test: self, storage: storage)
        let model = root.session.model
        await root.expect("compact composer") { root.composer?.text == "Picked for Inbox" }
        let created = await model.createList(name: "Other")
        XCTAssertTrue(created)
        let other = try XCTUnwrap(model.lists.first { $0.name == "Other" })
        model.selectList(SnipList.inboxID)
        storage.presentAttachmentPicker(ComposerAttachmentPickerRequest(source: .files, listID: SnipList.inboxID))

        let picked = try makePickedFile()
        await root.swap(to: .regular)
        model.selectList(other.id)
        storage.stagePickedMedia(.success(.files([picked])), to: SnipList.inboxID, model: model)
        XCTAssertNil(storage.attachmentPicker)
        await storage.stagingTask?.value

        let staged = storage.draftStore.draft(for: SnipList.inboxID).attachments
        XCTAssertEqual(staged.map(\.lastPathComponent), ["picked.txt"])
        XCTAssertEqual(storage.draftStore.draft(for: other.id).attachments, [])
        model.selectList(SnipList.inboxID)
        // This harness can't see the attachment strip. The text shows the composer loaded the Inbox
        // draft, which holds the attachment.
        let shown = await TestReadiness.wait { root.composer?.text == "Picked for Inbox" }
        XCTAssertTrue(shown, root.diagnostics)
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID).attachments, staged)
    }

    func testFilesPickerCallbackStagesIntoTheListThatOpenedIt() async throws {
        let storage = makeComposerStorage()
        let root = try RootHarness(test: self, storage: storage)
        let model = root.session.model
        await root.expect("compact composer") { root.composer != nil }
        let created = await model.createList(name: "Other")
        XCTAssertTrue(created)
        let other = try XCTUnwrap(model.lists.first { $0.name == "Other" })
        model.selectList(SnipList.inboxID)

        try await deliverThroughFilesPicker("for-inbox.txt", openedFor: SnipList.inboxID, storage: storage, root: root) {
            await root.swap(to: .regular)
            model.selectList(other.id)
        }
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID).attachments.map(\.lastPathComponent), ["for-inbox.txt"])
        XCTAssertEqual(storage.draftStore.draft(for: other.id).attachments, [])

        // A list kept from the first request would send this file to Inbox.
        try await deliverThroughFilesPicker("for-other.txt", openedFor: other.id, storage: storage, root: root)
        XCTAssertEqual(storage.draftStore.draft(for: other.id).attachments.map(\.lastPathComponent), ["for-other.txt"])
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID).attachments.map(\.lastPathComponent), ["for-inbox.txt"])
    }

    func testComposerKeyboardYieldsToAPreviewAcrossSizeClassSwap() async throws {
        let storage = makeComposerStorage()
        let attachment = try addInboxDraft("Preview draft", to: storage)
        try await assertKeyboardYields(
            storage: storage,
            present: { storage.presentAttachmentPreview(ComposerAttachmentPreviewRequest(url: attachment, listID: SnipList.inboxID)) },
            dismiss: { storage.dismissAttachmentPreview() }
        )
    }

    func testComposerKeyboardYieldsToAFilesPickerAcrossSizeClassSwap() async throws {
        let storage = makeComposerStorage()
        storage.draftStore.setText("Picker draft", for: SnipList.inboxID)
        try await assertKeyboardYields(
            storage: storage,
            present: { storage.presentAttachmentPicker(ComposerAttachmentPickerRequest(source: .files, listID: SnipList.inboxID)) },
            dismiss: { storage.dismissAttachmentPicker() }
        )
    }

    /// The camera can't redraw for a new size, so a swap closes it. Files, Photos, and a preview stay open.
    /// This storage-level test runs everywhere; `testRootClosesTheCameraWhenItSwapsLayouts` covers the
    /// root's wiring where a camera exists.
    func testLayoutSwapClosesOnlyTheCameraAndKeepsTheDraft() throws {
        let storage = makeComposerStorage()
        let attachment = try addInboxDraft("Camera draft", to: storage)
        let draft = storage.draftStore.draft(for: SnipList.inboxID)

        storage.presentAttachmentPicker(ComposerAttachmentPickerRequest(source: .camera, listID: SnipList.inboxID))
        storage.layoutDidSwap()
        XCTAssertNil(storage.attachmentPicker, "A layout swap must close the camera")
        XCTAssertNil(storage.stagingTask)
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID), draft)

        for source in [AttachmentSource.files, .photos] {
            let request = ComposerAttachmentPickerRequest(source: source, listID: SnipList.inboxID)
            storage.presentAttachmentPicker(request)
            storage.layoutDidSwap()
            XCTAssertEqual(storage.attachmentPicker, request, "\(source)")
        }
        storage.dismissAttachmentPicker()
        let preview = ComposerAttachmentPreviewRequest(url: attachment, listID: SnipList.inboxID)
        storage.presentAttachmentPreview(preview)
        storage.layoutDidSwap()
        XCTAssertEqual(storage.attachmentPreview, preview)
        XCTAssertNil(storage.stagingTask)
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID), draft)
    }

    /// Swaps the real root with the camera up. Presenting the camera raises where
    /// `isSourceTypeAvailable(.camera)` is false, as on many iPhone simulators and CI, so it skips there;
    /// the iPhone Duo simulator has a camera.
    func testRootClosesTheCameraWhenItSwapsLayouts() async throws {
        try XCTSkipUnless(UIImagePickerController.isSourceTypeAvailable(.camera), "This simulator has no camera.")
        let storage = makeComposerStorage()
        _ = try addInboxDraft("Camera draft", to: storage)
        let draft = storage.draftStore.draft(for: SnipList.inboxID)
        let root = try RootHarness(test: self, storage: storage)
        await root.expect("compact composer") { root.composer?.text == "Camera draft" }
        let request = ComposerAttachmentPickerRequest(source: .camera, listID: SnipList.inboxID)
        storage.presentAttachmentPicker(request)
        await root.expect("camera presented") { root.presented(UIImagePickerController.self) != nil }

        await root.swap(to: .regular)
        await root.settle()
        XCTAssertNil(storage.attachmentPicker, "The root's layout swap must close the camera")
        await root.expect("camera dismissed") { root.presented(UIImagePickerController.self) == nil }
        XCTAssertNil(storage.stagingTask)
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID), draft)

        // Presentation state must still follow the request after the swap's dismissal.
        storage.presentAttachmentPicker(request)
        await root.expect("camera presented again") { root.presented(UIImagePickerController.self) != nil }
        storage.dismissAttachmentPicker()
        await root.expect("camera dismissed again") { root.presented(UIImagePickerController.self) == nil }
    }

    func testCancelledPickerClearsItsRequestAndStagesNothing() {
        let storage = makeComposerStorage()
        let model = makeModel(library: ModelTestLibrary())
        storage.presentAttachmentPicker(ComposerAttachmentPickerRequest(source: .photos, listID: SnipList.inboxID))

        storage.stagePickedMedia(.failure(CocoaError(.userCancelled)), to: SnipList.inboxID, model: model)

        XCTAssertNil(storage.attachmentPicker)
        XCTAssertNil(storage.stagingTask)
        XCTAssertEqual(storage.draftStore.draft(for: SnipList.inboxID), ComposerDraft())
        XCTAssertNil(model.latestFailure)
    }

    /// Holds a save of the Inbox draft in `gate` while the compact composer is replaced by a regular one.
    private func startSaveAndSwap(
        _ storage: CompactComposerStorage, root: RootHarness, gate: SaveGate
    ) async throws -> Task<Bool, Never> {
        let draft = storage.draftStore.draft(for: SnipList.inboxID).text
        await root.expect("compact composer") { root.composer?.text == draft }
        let compact = try XCTUnwrap(root.composer)
        let saving = Task { await storage.save(listID: SnipList.inboxID, create: gate.create) }
        // The save runs on the main actor, so the test must suspend, not spin the run loop, to let it start.
        let started = await TestReadiness.wait { gate.draft != nil }
        XCTAssertTrue(started, "The save must start and wait in the gate.")
        XCTAssertEqual(gate.draft?.text, draft)
        await root.swap(to: .regular)
        await root.expect("regular composer mounted mid-save") {
            root.composer !== compact && root.composer?.text == "" && root.composer?.isEditable == false
        }
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

    /// Focuses the compact composer, presents, swaps to regular, then dismisses. The composer the swap
    /// mounts must leave the keyboard to the presentation, then take focus back once it closes.
    private func assertKeyboardYields(
        storage: CompactComposerStorage, present: () -> Void, dismiss: () -> Void
    ) async throws {
        let root = try RootHarness(test: self, storage: storage)
        await root.expect("compact composer") { root.composer != nil }
        let compact = try XCTUnwrap(root.composer)
        XCTAssertTrue(compact.becomeFirstResponder())
        await root.expect("compact composer focused") { root.composer?.isFirstResponder == true }

        present()
        // A system-style resign under the presentation must not clear the user's focus.
        compact.resignFirstResponder()
        await root.expect("compact composer yields the keyboard") { compact.isFirstResponder == false }
        // The resign reports focus loss from a queued block that skips a field no longer in a window,
        // so let it run before the swap removes this one. The setter guard is what must discard it.
        await root.settle()
        await root.swap(to: .regular)
        await root.settle()
        let regular = try XCTUnwrap(root.composer)
        XCTAssertFalse(regular === compact, root.diagnostics)
        XCTAssertFalse(regular.isFirstResponder, "The mounted composer took the keyboard under the presentation. \(root.diagnostics)")

        dismiss()
        await root.expect("regular composer takes focus back") { regular.isFirstResponder }
    }

    /// Opens the Files picker for `listID`, runs `meanwhile`, then picks `fileName` through the presented
    /// picker's delegate, so SwiftUI's own completion delivers it.
    private func deliverThroughFilesPicker(
        _ fileName: String, openedFor listID: UUID, storage: CompactComposerStorage, root: RootHarness,
        meanwhile: () async -> Void = {}
    ) async throws {
        storage.presentAttachmentPicker(ComposerAttachmentPickerRequest(source: .files, listID: listID))
        let opened = await TestReadiness.wait { root.presented(UIDocumentPickerViewController.self) != nil }
        XCTAssertTrue(opened, "The Files picker must open")
        let picker = try XCTUnwrap(root.presented(UIDocumentPickerViewController.self))
        await meanwhile()
        let delegate = try XCTUnwrap(picker.delegate, "SwiftUI's file importer must set the picker's delegate")
        let file = try makePickedFile(named: fileName)
        // Mirrors UIKit, which dismisses the picker before it calls the delegate.
        picker.dismiss(animated: false)
        let dismissed = await TestReadiness.wait { root.presented(UIDocumentPickerViewController.self) == nil }
        XCTAssertTrue(dismissed, "The Files picker must close before it delivers")
        let delivered: Void? = delegate.documentPicker?(picker, didPickDocumentsAt: [file])
        XCTAssertNotNil(delivered, "The picker's delegate must handle picked documents")
        let staged = await TestReadiness.wait {
            storage.attachmentPicker == nil && storage.stagingTask == nil
                && storage.draftStore.draft(for: listID).attachments.contains { $0.lastPathComponent == fileName }
        }
        XCTAssertTrue(staged, "\(fileName) must stage into its list and clear the request")
        let closed = await TestReadiness.wait { root.presented(UIDocumentPickerViewController.self) == nil }
        XCTAssertTrue(closed, "The Files picker must close")
    }

    /// A file outside the staging directory, as the Files picker returns.
    private func makePickedFile(named fileName: String = "picked.txt") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(fileName)
        try Data("picked".utf8).write(to: file)
        return file
    }

    private func makeComposerStorage() -> CompactComposerStorage {
        let suite = "fold-continuity-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return CompactComposerStorage(defaults: defaults)
    }
}

final class IOSFoldContinuitySidebarTests: IOSFoldContinuityTests {
    override class var regularLayout: RegularLibraryLayout { .sidebar }
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
    private let layout: RegularLibraryLayout

    init(test: IOSFoldContinuityTests, storage: CompactComposerStorage, library: ModelTestLibrary = ModelTestLibrary()) throws {
        session = IOSAppSession(library: library)
        layout = type(of: test).regularLayout
        host = UIHostingController(rootView: IOSAppRootView(
            session: session, composerStorage: storage, regularLayout: layout
        ))
        host.traitOverrides.horizontalSizeClass = .compact
        window = try makeWindow(host)
        test.addTeardownBlock { @MainActor [self] in await close() }
    }

    /// Ends this test's presentations and empties its window, then lets pending layout run while the
    /// views still exist, so nothing laid out later can reach a view this test freed.
    private func close() async {
        if host.presentedViewController != nil {
            host.dismiss(animated: false)
            await expect("presentations end before teardown") { host.presentedViewController == nil }
        }
        window.isHidden = true
        window.rootViewController = nil
        try? await Task.sleep(for: .milliseconds(100))
    }

    func swap(to sizeClass: UIUserInterfaceSizeClass, file: StaticString = #filePath, line: UInt = #line) async {
        host.traitOverrides.horizontalSizeClass = sizeClass
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await expect("\(sizeClass) tree mounted", file: file, line: line) { self.isRegular == (sizeClass == .regular) }
    }

    // An async test runs as a job on the main queue. Spinning the run loop there (`XCTWaiter.wait`,
    // `RunLoop.run`) can't drain that queue, so SwiftUI and UIKit work queued on it never runs and the
    // wait hangs. Harness waits suspend instead, so every test that uses the harness is async.

    /// Gives teardown callbacks, deferred focus, and presentation updates time to run.
    func settle() async {
        try? await Task.sleep(for: .seconds(1))
    }

    /// Fails with `description` and `details` (the harness diagnostics by default) unless `condition`
    /// holds within `TestReadiness.timeout`.
    func expect(
        _ description: String, details: @autoclosure () -> String? = nil,
        file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool
    ) async {
        guard await !TestReadiness.wait(until: { condition() }) else { return }
        XCTFail("Timed out: \(description). \(details() ?? diagnostics)", file: file, line: line)
    }

    var diagnostics: String {
        let composers = allViews(ComposerTextView.self).map {
            "text=\($0.text ?? "nil") window=\($0.window != nil) hidden=\($0.isHidden) frame=\($0.frame)"
        }
        return "regular=\(isRegular) composers=\(composers) windowFrame=\(window.frame)"
    }

    var isRegular: Bool {
        switch layout {
        case .sidebar:
            first(UISplitViewController.self, in: host) != nil
        case .rail:
            // The compact tree pages lists through `ListPagePanObserver`; the rail has none.
            first(UISplitViewController.self, in: host) == nil
                && first(UINavigationController.self, in: host) != nil
                && allViews(ListPagePanObserver.AttachmentView.self).isEmpty
        }
    }

    /// A controller the root presents, such as a system picker, or one anywhere inside a presented container,
    /// as a full-screen cover nests its content.
    func presented<Controller: UIViewController>(_ type: Controller.Type) -> Controller? {
        func search(_ controller: UIViewController) -> Controller? {
            (controller as? Controller) ?? controller.children.lazy.compactMap(search).first
        }
        var next = host.presentedViewController
        while let controller = next {
            if let match = search(controller) { return match }
            next = controller.presentedViewController
        }
        return nil
    }

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
