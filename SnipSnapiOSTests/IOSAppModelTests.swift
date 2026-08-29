import SnipSnapCore
import SwiftUI
import UIKit
import XCTest
@testable import SnipSnapiOS

@MainActor
final class IOSAppModelTests: XCTestCase {
    func testAccountNoticeInvokesHandlerAndHidesAfterKeepLocalCopy() async {
        let handler = IOSAppleAccountCacheHandlerProbe()
        let model = AppleAccountNoticeModel(notice: .signedOut, handler: handler)
        XCTAssertEqual(model.notice, .signedOut)

        await model.resolve(.keepLocalCopy)

        XCTAssertNil(model.notice)
        let choices = await handler.choices()
        XCTAssertEqual(choices, [.keepLocalCopy])
    }

    func testLocalOnlyAssemblyCannotShowAnAccountNoticeWithoutAHandler() {
        let model = AppleAccountNoticeModel(notice: .accountChanged, handler: nil)
        XCTAssertNil(model.notice)
    }

    func testPausedNoticeRendersWithoutCacheChoices() {
        let model = AppleAccountNoticeModel(
            notice: .paused,
            handler: IOSAppleAccountCacheHandlerProbe()
        )

        XCTAssertEqual(model.title, "iCloud Sync Paused")
        XCTAssertTrue(model.message.contains("still on this device"))
        XCTAssertFalse(model.showsResolutionActions)
    }

    func testAccountNoticeRefreshReadsTheProductionHandlerSeam() async {
        let handler = IOSAppleAccountCacheHandlerProbe(notices: [.accountChanged, nil])
        let model = AppleAccountNoticeModel(handler: handler)

        await model.refresh()
        XCTAssertEqual(model.notice, .accountChanged)

        await model.resolve(.remove)
        XCTAssertNil(model.notice)
        let choices = await handler.choices()
        let refreshCount = await handler.refreshCount()
        XCTAssertEqual(choices, [.remove])
        XCTAssertEqual(refreshCount, 2)
    }

    func testRemoteAttachmentShowsWaitingSyncingAndAvailableStates() async throws {
        let attachmentID = UUID()
        let handler = IOSCloudSyncHandlerProbe(states: [attachmentID: .waiting])
        let model = IOSAppModel(
            library: ModelTestLibrary(),
            cloudSyncHandler: handler
        )
        await model.load()
        XCTAssertEqual(model.attachmentTransferState(for: attachmentID), .waiting)

        let preparing = Task { await model.prepareAttachment(attachmentID, for: .preview) }
        await handler.waitUntilPrepareStarts()
        XCTAssertEqual(model.attachmentTransferState(for: attachmentID), .syncing)
        let downloaded = URL(fileURLWithPath: "/tmp/downloaded-remote.txt")
        await handler.finishPrepare(with: .success(downloaded))
        let preparedURL = await preparing.value
        XCTAssertEqual(preparedURL, downloaded)
        XCTAssertEqual(model.attachmentURL(for: attachmentID), downloaded)
        XCTAssertEqual(model.attachmentTransferState(for: attachmentID), .available)
    }

    func testRemoteAttachmentFailureStaysVisibleForRetry() async {
        let id = UUID()
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let model = IOSAppModel(library: ModelTestLibrary(), cloudSyncHandler: handler)
        await model.load()
        let preparing = Task { await model.prepareAttachment(id, for: .open) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .failure(SnipLibraryError.attachmentCopyFailed))
        let preparedURL = await preparing.value
        XCTAssertNil(preparedURL)
        XCTAssertEqual(model.attachmentTransferState(for: id), .failed)
        XCTAssertNotNil(model.errorMessage)
    }

    func testSyncedLocalAttachmentStillUsesVerifiedTransferPath() async throws {
        let id = UUID()
        let local = URL(fileURLWithPath: "/tmp/unverified-local.txt")
        let verified = URL(fileURLWithPath: "/tmp/verified-local.txt")
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let model = IOSAppModel(
            library: ModelTestLibrary(attachmentURLs: [id: local]),
            cloudSyncHandler: handler
        )
        await model.load()
        XCTAssertNil(model.attachmentURL(for: id))

        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .success(verified))

        let preparedURL = await preparing.value
        XCTAssertEqual(preparedURL, verified)
        XCTAssertEqual(model.attachmentURL(for: id), verified)
    }

    func testLocalAttachmentStaysUsableWhenCloudHandlerHasNoSyncedState() async {
        let id = UUID()
        let local = URL(fileURLWithPath: "/tmp/local-only.txt")
        let handler = IOSCloudSyncHandlerProbe(states: [:], isActive: false)
        let model = IOSAppModel(
            library: ModelTestLibrary(attachmentURLs: [id: local]),
            cloudSyncHandler: handler
        )

        await model.load()

        XCTAssertEqual(model.attachmentURL(for: id), local)
        XCTAssertFalse(model.hasCloudSync)
        let prepared = await model.prepareAttachment(id, for: .preview)
        XCTAssertEqual(prepared, local)
        let prepareCount = await handler.prepareCount()
        XCTAssertEqual(prepareCount, 0)
    }

    func testLocalAttachmentStaysUsableWithoutACloudHandler() async {
        let id = UUID()
        let local = URL(fileURLWithPath: "/tmp/no-cloud-handler.txt")
        let model = IOSAppModel(
            library: ModelTestLibrary(attachmentURLs: [id: local])
        )

        await model.load()

        XCTAssertEqual(model.attachmentURL(for: id), local)
        XCTAssertEqual(model.attachmentTransferState(for: id), .available)
        XCTAssertFalse(model.hasCloudSync)
    }

    func testNewOfflineAttachmentStaysUsableUntilSyncPublishesIt() async {
        let id = UUID()
        let local = URL(fileURLWithPath: "/tmp/new-offline.txt")
        let handler = IOSCloudSyncHandlerProbe(states: [:])
        let model = IOSAppModel(
            library: ModelTestLibrary(attachmentURLs: [id: local]),
            cloudSyncHandler: handler
        )

        await model.load()

        XCTAssertEqual(model.attachmentTransferState(for: id), .available)
        let prepared = await model.prepareAttachment(id, for: .open)
        XCTAssertEqual(prepared, local)
        let prepareCount = await handler.prepareCount()
        XCTAssertEqual(prepareCount, 0)
    }

    func testUnknownCloudAttachmentStateNeverExposesAnUnverifiedLocalURL() async {
        let id = UUID()
        let local = URL(fileURLWithPath: "/tmp/unknown-cloud-state.txt")
        let verified = URL(fileURLWithPath: "/tmp/verified-after-state-failure.txt")
        let handler = IOSCloudSyncHandlerProbe(states: [:], stateReadFails: true)
        let model = IOSAppModel(
            library: ModelTestLibrary(attachmentURLs: [id: local]),
            cloudSyncHandler: handler
        )

        await model.load()

        XCTAssertNil(model.attachmentURL(for: id))
        XCTAssertEqual(model.attachmentTransferState(for: id), .waiting)
        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .success(verified))
        let prepared = await preparing.value
        XCTAssertEqual(prepared, verified)
        XCTAssertEqual(model.attachmentURL(for: id), verified)
    }

    func testUnknownCloudModeNeverExposesAnUnverifiedLocalURL() async {
        let id = UUID()
        let local = URL(fileURLWithPath: "/tmp/unknown-cloud-mode.txt")
        let verified = URL(fileURLWithPath: "/tmp/verified-after-mode-failure.txt")
        let handler = IOSCloudSyncHandlerProbe(states: [:], activeReadFails: true)
        let model = IOSAppModel(
            library: ModelTestLibrary(attachmentURLs: [id: local]),
            cloudSyncHandler: handler
        )

        await model.load()

        XCTAssertNil(model.attachmentURL(for: id))
        XCTAssertEqual(model.attachmentTransferState(for: id), .waiting)
        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .success(verified))
        let prepared = await preparing.value
        XCTAssertEqual(prepared, verified)
        XCTAssertEqual(model.attachmentURL(for: id), verified)
    }

    func testModeReadFailureAfterInactiveStateStillUsesVerifiedPrepare() async {
        let id = UUID()
        let local = URL(fileURLWithPath: "/tmp/inactive-then-unknown.txt")
        let verified = URL(fileURLWithPath: "/tmp/verified-after-mode-transition.txt")
        let handler = IOSCloudSyncHandlerProbe(
            states: [:],
            isActive: false,
            activeReadFailsAfterFirst: true
        )
        let model = IOSAppModel(
            library: ModelTestLibrary(attachmentURLs: [id: local]),
            cloudSyncHandler: handler
        )

        await model.load()
        XCTAssertEqual(model.attachmentURL(for: id), local)

        await model.load()
        XCTAssertNil(model.attachmentURL(for: id))
        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .success(verified))
        let prepared = await preparing.value
        XCTAssertEqual(prepared, verified)
        XCTAssertEqual(model.attachmentURL(for: id), verified)
    }

    func testExistingEditorDraftUsesVerifiedPrepareEvenWithALocalURL() async {
        let id = UUID()
        let local = URL(fileURLWithPath: "/tmp/unverified-editor-local.txt")
        let verified = URL(fileURLWithPath: "/tmp/verified-editor-local.txt")
        let draft = AttachmentDraft(
            id: id,
            fileName: "local.txt",
            byteCount: 5,
            url: local,
            source: .existing(attachmentID: id)
        )
        var preparedIDs: [UUID] = []

        let result = await draft.previewURL { attachmentID in
            preparedIDs.append(attachmentID)
            return verified
        }

        XCTAssertEqual(result, verified)
        XCTAssertEqual(preparedIDs, [id])
    }

    func testFinishedCloudPreviewCannotOverwriteAStagedReplacement() {
        let id = UUID()
        let requested = AttachmentDraft(
            id: id,
            fileName: "old.txt",
            byteCount: 3,
            url: nil,
            source: .existing(attachmentID: id)
        )
        let replacement = AttachmentDraft(
            id: id,
            fileName: "replacement.txt",
            byteCount: 11,
            url: URL(fileURLWithPath: "/tmp/replacement.txt"),
            source: .replacement(attachmentID: id)
        )

        let changed = replacement.applyingPreparedURL(
            URL(fileURLWithPath: "/tmp/old-cloud-download.txt"),
            requestedDraft: requested
        )

        XCTAssertNil(changed)
        XCTAssertEqual(replacement.url?.lastPathComponent, "replacement.txt")
    }

    func testFinishedReplacementPreviewCannotOverwriteANewerReplacement() {
        let id = UUID()
        let requested = AttachmentDraft(
            id: id,
            fileName: "first.txt",
            byteCount: 5,
            url: URL(fileURLWithPath: "/tmp/first.txt"),
            source: .replacement(attachmentID: id)
        )
        let current = AttachmentDraft(
            id: id,
            fileName: "second.txt",
            byteCount: 6,
            url: URL(fileURLWithPath: "/tmp/second.txt"),
            source: .replacement(attachmentID: id)
        )

        XCTAssertNil(current.applyingPreparedURL(
            URL(fileURLWithPath: "/tmp/first-preview.txt"),
            requestedDraft: requested
        ))
    }

    func testFinishedAddedPreviewCannotOverwriteANewerAddedDraft() {
        let id = UUID()
        let requested = AttachmentDraft(
            id: id,
            fileName: "first.txt",
            byteCount: 5,
            url: URL(fileURLWithPath: "/tmp/first.txt"),
            source: .added
        )
        let current = AttachmentDraft(
            id: id,
            fileName: "second.txt",
            byteCount: 6,
            url: URL(fileURLWithPath: "/tmp/second.txt"),
            source: .added
        )

        XCTAssertNil(current.applyingPreparedURL(
            URL(fileURLWithPath: "/tmp/first-preview.txt"),
            requestedDraft: requested
        ))
    }

    func testManualSyncUsesTheProductionHandlerSeam() async {
        let handler = IOSCloudSyncHandlerProbe(states: [:])
        let model = IOSAppModel(library: ModelTestLibrary(), cloudSyncHandler: handler)

        await model.syncWhenPossible()

        let syncCount = await handler.syncCount()
        XCTAssertEqual(syncCount, 1)
    }

    func testRootReinitializationKeepsForegroundImportOnRetainedGraph() async throws {
        let library = ModelTestLibrary()
        let firstProbe = ImportCallProbe()
        let secondProbe = ImportCallProbe()
        let state = RootReinitHarnessState()
        let host = UIHostingController(
            rootView: RootReinitHarness(
                state: state,
                library: library,
                firstProbe: firstProbe,
                secondProbe: secondProbe
            )
        )
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let didLaunch = await waitForCalls(1, from: firstProbe)
        XCTAssertTrue(didLaunch)
        state.generation = 1
        try? await Task.sleep(for: .milliseconds(30))
        state.phase = .background
        try? await Task.sleep(for: .milliseconds(30))
        state.phase = .active

        let didImportOnForeground = await waitForCalls(2, from: firstProbe)
        XCTAssertTrue(didImportOnForeground)
        let discardedGraphCalls = await secondProbe.callCount()
        XCTAssertEqual(discardedGraphCalls, 0)
    }

    func testLaunchAndForegroundShareOneImportThenALaterForegroundRunsAgain() async {
        let snip = Snip(
            requestID: UUID(),
            content: "From Share",
            origin: .share,
            listID: SnipList.inboxID
        )
        let library = ModelTestLibrary(snips: [snip])
        let model = IOSAppModel(library: library)
        let probe = PendingImportProbe()
        let coordinator = IOSShareImportCoordinator(
            model: model,
            importOperation: { await probe.run() }
        )

        let launch = Task { await coordinator.importPendingAndReload() }
        await probe.waitUntilFirstImportStarts()
        let overlappingForeground = Task { await coordinator.importPendingAndReload() }
        await Task.yield()
        await probe.finishFirstImport()
        await launch.value
        await overlappingForeground.value

        let overlappingCallCount = await probe.callCount()
        XCTAssertEqual(overlappingCallCount, 1)
        XCTAssertEqual(model.snips.map(\.id), [snip.id])

        await coordinator.importPendingAndReload()
        let foregroundCallCount = await probe.callCount()
        XCTAssertEqual(foregroundCallCount, 2)
    }

    func testAttachmentDraftCleanupWaitsForChildPresentations() {
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsDismissal(isSaving: false, isStaging: true)
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsDismissal(isSaving: true, isStaging: false)
        )
        XCTAssertTrue(
            AttachmentDraftLifecycle.allowsDismissal(isSaving: false, isStaging: false)
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: true,
                isStaging: false,
                isImporting: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: true,
                isImporting: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: true,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPreviewing: true
            )
        )
        XCTAssertTrue(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.shouldClean(
                isSaving: false,
                isStaging: false,
                isImporting: true,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.shouldClean(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPreviewing: true
            )
        )
        XCTAssertTrue(
            AttachmentDraftLifecycle.shouldClean(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPreviewing: false
            )
        )
    }

    func testTextSnipFlowCreatesEditsMovesAndDeletes() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()

        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        let createdSnip = await model.createSnip(content: "First draft", in: SnipList.inboxID)
        XCTAssertTrue(createdSnip)
        let snip = try XCTUnwrap(model.selectedSnip)

        let editedSnip = await model.editSnip(snip, content: "Final draft")
        XCTAssertTrue(editedSnip)
        XCTAssertEqual(model.selectedSnip?.content, "Final draft")

        let movedSnip = await model.moveSnip(id: snip.id, to: workID)
        XCTAssertTrue(movedSnip)
        XCTAssertEqual(model.selectedListID, workID)
        XCTAssertEqual(model.selectedSnip?.listID, workID)

        let deletedSnip = await model.deleteSnip(id: snip.id)
        XCTAssertTrue(deletedSnip)
        XCTAssertTrue(model.snips.isEmpty)
        XCTAssertNil(model.selectedSnipID)
        let pruneCalls = await library.pruneCalls()
        XCTAssertEqual(pruneCalls, 1)
    }

    func testListFlowKeepsInboxAsFallback() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()

        let createdList = await model.createList(name: "Notes")
        XCTAssertTrue(createdList)
        let list = try XCTUnwrap(model.lists.first(where: { $0.name == "Notes" }))
        let createdSnip = await model.createSnip(content: "Keep me", in: list.id)
        XCTAssertTrue(createdSnip)
        let renamedList = await model.renameList(list, name: "Ideas")
        XCTAssertTrue(renamedList)
        XCTAssertEqual(model.lists.first(where: { $0.id == list.id })?.name, "Ideas")

        let deletedList = await model.deleteList(id: list.id)
        XCTAssertTrue(deletedList)
        XCTAssertEqual(model.selectedListID, SnipList.inboxID)
        XCTAssertEqual(model.snips.first?.listID, SnipList.inboxID)
        XCTAssertEqual(model.lists.first, .inbox)
    }

    func testAttachmentInputsUseTheTargetedLibraryCommands() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()
        let sourceURL = URL(fileURLWithPath: "/tmp/first-file.txt")
        let replacementURL = URL(fileURLWithPath: "/tmp/replacement-file.txt")

        let created = await model.createSnip(
            content: "",
            in: SnipList.inboxID,
            attachmentURLs: [sourceURL]
        )
        XCTAssertTrue(created)
        let addedURLs = await library.addedAttachmentURLs()
        XCTAssertEqual(addedURLs, [sourceURL])
        let snip = try XCTUnwrap(model.selectedSnip)

        let edited = await model.editSnip(
            snip,
            content: "Now with a file",
            attachmentEdits: [.added(sourceURL: replacementURL)]
        )
        XCTAssertTrue(edited)
        let edit = await library.lastAttachmentEdit
        XCTAssertEqual(edit?.snipID, snip.id)
        XCTAssertEqual(edit?.content, "Now with a file")
        XCTAssertEqual(edit?.edits, [.added(sourceURL: replacementURL)])
    }

    func testAttachmentDraftStagingCopiesAndCleansTemporaryInput() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftStagingTests-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftSourceTests-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = sourceRoot.appendingPathComponent("draft.txt")
        defer {
            AttachmentDraftStager.clean(testRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("Draft bytes".utf8).write(to: sourceURL)

        let staged = try await AttachmentDraftStager.stage([sourceURL], in: testRoot)
        let stagedFile = try XCTUnwrap(staged.first)
        XCTAssertNotEqual(stagedFile.url, sourceURL)
        XCTAssertEqual(try Data(contentsOf: stagedFile.url), Data("Draft bytes".utf8))

        AttachmentDraftStager.clean(testRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile.url.path))
    }

    func testFailedStagingBatchKeepsFilesFromAnEarlierBatch() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftBatchTests-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftBatchSources-\(UUID().uuidString)", isDirectory: true)
        let validURL = sourceRoot.appendingPathComponent("valid.txt")
        let missingURL = sourceRoot.appendingPathComponent("missing.txt")
        defer {
            AttachmentDraftStager.clean(testRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("Keep this".utf8).write(to: validURL)

        let firstBatch = try await AttachmentDraftStager.stage([validURL], in: testRoot)
        let keptURL = try XCTUnwrap(firstBatch.first?.url)
        do {
            _ = try await AttachmentDraftStager.stage([missingURL], in: testRoot)
            XCTFail("A missing file should fail staging.")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: keptURL), Data("Keep this".utf8))
    }

    func testAttachmentDraftStagingRejectsSymbolicLinks() async throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftLinkTests-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapDraftLinkSources-\(UUID().uuidString)", isDirectory: true)
        let targetURL = sourceRoot.appendingPathComponent("target.txt")
        let linkURL = sourceRoot.appendingPathComponent("link.txt")
        defer {
            AttachmentDraftStager.clean(testRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("Outside bytes".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        do {
            _ = try await AttachmentDraftStager.stage([linkURL], in: testRoot)
            XCTFail("A symbolic link should not become an attachment draft.")
        } catch {
            XCTAssertEqual(error as? SnipLibraryError, .attachmentCopyFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: testRoot.path))
    }

    func testTargetCannotCompileAppKit() {
        #if canImport(AppKit)
        XCTFail("The universal iOS target must not compile AppKit.")
        #endif
    }

    private func waitForCalls(_ expected: Int, from probe: ImportCallProbe) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await probe.callCount() < expected, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await probe.callCount() >= expected
    }
}

private actor IOSAppleAccountCacheHandlerProbe: AppleAccountCacheHandling {
    private var received: [AppleAccountCacheChoice] = []
    private var notices: [AppleAccountNotice?]
    private var noticeReads = 0

    init(notices: [AppleAccountNotice?] = []) {
        self.notices = notices
    }

    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? {
        defer { noticeReads += 1 }
        return notices.indices.contains(noticeReads) ? notices[noticeReads] : nil
    }

    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {
        received.append(choice)
    }

    func choices() -> [AppleAccountCacheChoice] { received }
    func refreshCount() -> Int { noticeReads }
}

private actor IOSCloudSyncHandlerProbe: OptionalCloudSyncHandling {
    private let states: [UUID: SyncedAttachmentTransferState]
    private let active: Bool
    private let activeReadFails: Bool
    private let activeReadFailsAfterFirst: Bool
    private let stateReadFails: Bool
    private var activeReadCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var prepareContinuation: CheckedContinuation<URL, any Error>?
    private var prepareStarted = false
    private var syncCalls = 0
    private var prepareCalls = 0

    init(
        states: [UUID: SyncedAttachmentTransferState],
        isActive: Bool = true,
        activeReadFails: Bool = false,
        activeReadFailsAfterFirst: Bool = false,
        stateReadFails: Bool = false
    ) {
        self.states = states
        active = isActive
        self.activeReadFails = activeReadFails
        self.activeReadFailsAfterFirst = activeReadFailsAfterFirst
        self.stateReadFails = stateReadFails
    }

    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
    func syncWhenPossible() async { syncCalls += 1 }
    func isCloudSyncActive() async throws -> Bool {
        defer { activeReadCount += 1 }
        if activeReadFails || (activeReadFailsAfterFirst && activeReadCount > 0) {
            throw SnipLibraryError.storeUnavailable
        }
        return active
    }
    func syncCount() -> Int { syncCalls }
    func prepareCount() -> Int { prepareCalls }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] {
        if stateReadFails { throw SnipLibraryError.storeUnavailable }
        return states
    }
    func clearDownloadedFiles() async throws {}

    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        prepareCalls += 1
        prepareStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return try await withCheckedThrowingContinuation { prepareContinuation = $0 }
    }

    func waitUntilPrepareStarts() async {
        if prepareStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishPrepare(with result: Result<URL, any Error>) {
        switch result {
        case .success(let url): prepareContinuation?.resume(returning: url)
        case .failure(let error): prepareContinuation?.resume(throwing: error)
        }
        prepareContinuation = nil
    }
}

@MainActor
private final class RootReinitHarnessState: ObservableObject {
    @Published var generation = 0
    @Published var phase: ScenePhase = .active
}

private struct RootReinitHarness: View {
    @ObservedObject var state: RootReinitHarnessState
    let library: any SnipLibrary
    let firstProbe: ImportCallProbe
    let secondProbe: ImportCallProbe

    var body: some View {
        let probe = state.generation == 0 ? firstProbe : secondProbe
        IOSAppRootView(
            library: library,
            shareImportOperation: { await probe.run() }
        )
        .environment(\.scenePhase, state.phase)
    }
}

private actor ModelTestLibrary: SnipLibrary {
    private var snips: [Snip]
    private var lists: [SnipList] = [.inbox]
    private let attachmentURLs: [UUID: URL]
    private(set) var lastAddedAttachmentURLs: [URL] = []
    private(set) var lastAttachmentEdit: (snipID: UUID, content: String, edits: [SnipAttachmentEdit])?
    private var attachmentPruneCalls = 0

    init(snips: [Snip] = [], attachmentURLs: [UUID: URL] = [:]) {
        self.snips = snips
        self.attachmentURLs = attachmentURLs
    }

    func addedAttachmentURLs() -> [URL] {
        lastAddedAttachmentURLs
    }

    func pruneCalls() -> Int {
        attachmentPruneCalls
    }

    func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        makeSnapshot(sortMode: sortMode)
    }

    func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) throws -> SnipLibraryUpdate {
        let outcome: SnipLibraryOutcome
        switch command {
        case .add(
            let content, let origin, let source, let listID, let attachmentURLs, let requestID,
            let now
        ):
            lastAddedAttachmentURLs = attachmentURLs
            let snip = Snip(
                requestID: requestID,
                createdAt: now,
                content: content,
                origin: origin,
                source: source,
                listID: listID
            )
            snips.append(snip)
            outcome = .add(.added(snip.id))
        case .update(let id, let content, _, _, let now):
            guard let index = snips.firstIndex(where: { $0.id == id }) else {
                throw SnipLibraryError.snipNotFound
            }
            snips[index].content = content
            snips[index].updatedAt = now
            outcome = .none
        case .editAttachments(let snipID, let content, let edits, _, let now):
            guard let index = snips.firstIndex(where: { $0.id == snipID }) else {
                throw SnipLibraryError.snipNotFound
            }
            lastAttachmentEdit = (snipID, content, edits)
            snips[index].content = content
            snips[index].updatedAt = now
            outcome = .none
        case .delete(let ids):
            snips.removeAll { ids.contains($0.id) }
            outcome = .none
        case .pruneAttachments:
            attachmentPruneCalls += 1
            outcome = .none
        case .moveChronologically(let ids, let listID):
            for index in snips.indices where ids.contains(snips[index].id) {
                snips[index].listID = listID
            }
            outcome = .none
        case .createList(let name, let systemImage):
            let list = SnipList(
                id: UUID(),
                name: name,
                systemImage: systemImage,
                position: lists.count
            )
            lists.append(list)
            outcome = .listCreated(list)
        case .updateList(let id, let name, let systemImage):
            guard let index = lists.firstIndex(where: { $0.id == id }) else {
                throw SnipLibraryError.invalidList
            }
            lists[index].name = name
            lists[index].systemImage = systemImage
            outcome = .none
        case .deleteList(let id):
            lists.removeAll { $0.id == id }
            for index in snips.indices where snips[index].listID == id {
                snips[index].listID = SnipList.inboxID
            }
            outcome = .none
        default:
            outcome = .none
        }
        return SnipLibraryUpdate(snapshot: makeSnapshot(sortMode: sortMode), outcome: outcome)
    }

    private func makeSnapshot(sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        SnipLibrarySnapshot(
            snips: lists.flatMap { list in
                Snip.sorted(snips.filter { $0.listID == list.id }, by: sortMode)
            },
            lists: lists,
            attachmentURLs: attachmentURLs
        )
    }
}

private actor PendingImportProbe {
    private var calls = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstImportContinuation: CheckedContinuation<Void, Never>?

    func run() async -> Int {
        calls += 1
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if calls == 1 {
            await withCheckedContinuation { continuation in
                firstImportContinuation = continuation
            }
        }
        return 0
    }

    func waitUntilFirstImportStarts() async {
        if calls > 0 { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishFirstImport() {
        firstImportContinuation?.resume()
        firstImportContinuation = nil
    }

    func callCount() -> Int { calls }
}

private actor ImportCallProbe {
    private var calls = 0

    func run() -> Int {
        calls += 1
        return 0
    }

    func callCount() -> Int { calls }
}
