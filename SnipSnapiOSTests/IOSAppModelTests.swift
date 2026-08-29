import SnipSnapCore
import SnipSnapPersistence
import SwiftUI
import UIKit
import XCTest
@testable import SnipSnapiOS

@MainActor
final class IOSAppModelTests: XCTestCase {
    func testReplacingLibraryReloadsVisibleContentAndRecoveryScope() async {
        let old = Snip(content: "Old collection", origin: .quickEntry)
        let recoveredValue = Snip(content: "Recovered copy", origin: .quickEntry)
        let recovered = RecoveredSnip(
            id: recoveredValue.id,
            currentSnipID: recoveredValue.id,
            recovered: recoveredValue,
            conflictingFields: [],
            state: .promoted
        )
        let oldLibrary = ModelTestLibrary(snips: [old])
        let freshLibrary = ModelTestLibrary(
            recovery: SnipRecoverySnapshot(promotedSnips: [recovered])
        )
        let model = IOSAppModel(library: oldLibrary)
        await model.load()
        model.selectedSnipID = old.id

        await model.replaceLibrary(
            freshLibrary,
            recoveryScope: SnipRecoveryScope("fresh-scope")
        )

        XCTAssertTrue(model.snips.isEmpty)
        XCTAssertNil(model.selectedSnipID)
        XCTAssertEqual(model.recoverySnapshot.promotedSnips, [recovered])
    }

    func testExplicitSyncEnableReplacesTheVisibleLibraryBeforeReportingOn() async {
        let oldLibrary = ModelTestLibrary(
            snips: [Snip(content: "Local before enable", origin: .quickEntry)]
        )
        let cloudLibrary = ModelTestLibrary(
            snips: [Snip(content: "Merged after enable", origin: .quickEntry)]
        )
        let model = IOSAppModel(library: oldLibrary)
        await model.load()
        let settings = SyncedContentSettingsModel(mode: .localOnly, enableAction: {})
        settings.setEnableCompletionAction {
            await model.replaceLibrary(cloudLibrary, recoveryScope: nil)
        }

        await settings.enableICloudSync()

        XCTAssertEqual(settings.mode, .iCloudSync)
        XCTAssertEqual(model.snips.map(\.content), ["Merged after enable"])
    }

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
    func testCopySharePayloadsCoverTextFileMixedMultiAndUnavailableCases() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCopyPayload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appendingPathComponent("first.txt")
        let secondURL = directory.appendingPathComponent("second.txt")
        try Data("First".utf8).write(to: firstURL)
        try Data("Second".utf8).write(to: secondURL)
        let firstID = UUID()
        let secondID = UUID()
        let missingID = UUID()
        let firstAttachment = try testAttachment(id: firstID, fileName: "first.txt")
        let secondAttachment = try testAttachment(id: secondID, fileName: "second.txt")
        let missingAttachment = try testAttachment(id: missingID, fileName: "missing.txt")
        let old = Snip(
            createdAt: Date(timeIntervalSince1970: 1),
            content: "Old text",
            origin: .quickEntry
        )
        let fileOnly = Snip(
            createdAt: Date(timeIntervalSince1970: 2),
            content: "",
            origin: .quickEntry,
            attachments: [firstAttachment]
        )
        let mixed = Snip(
            createdAt: Date(timeIntervalSince1970: 3),
            content: "Mixed text",
            origin: .quickEntry,
            attachments: [secondAttachment]
        )
        let missing = Snip(
            createdAt: Date(timeIntervalSince1970: 4),
            content: "Keep this text",
            origin: .quickEntry,
            attachments: [missingAttachment]
        )
        let urls = [firstID: firstURL, secondID: secondURL]
        let builder = IOSCopySharePayloadBuilder()

        let textPayload = builder.payload(for: [old]) { urls[$0] }
        XCTAssertEqual(textPayload.copyItems, [.text("Old text")])

        let filePayload = builder.payload(for: [fileOnly]) { urls[$0] }
        XCTAssertEqual(filePayload.copyItems, [.text(""), .file(firstURL)])
        XCTAssertEqual(filePayload.attachmentItems, [.file(firstURL)])

        let mixedPayload = builder.payload(for: [mixed]) { urls[$0] }
        XCTAssertEqual(mixedPayload.copyItems, [.text("Mixed text"), .file(secondURL)])

        let multiPayload = builder.payload(for: [mixed, fileOnly, old]) { urls[$0] }
        XCTAssertEqual(multiPayload.text, SnipFormatter.formatForClipboard(snips: [mixed, fileOnly, old]))
        XCTAssertEqual(multiPayload.attachments, [firstURL, secondURL])

        let unavailablePayload = builder.payload(for: [missing]) { urls[$0] }
        XCTAssertEqual(unavailablePayload.unavailableFileNames, ["missing.txt"])
        XCTAssertEqual(unavailablePayload.copyItems, [.text("Keep this text")])
    }

    func testCopyShareCoordinatorWritesWholePlansAndStopsForUnavailableFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCopyCoordinator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("file.txt")
        try Data("File".utf8).write(to: fileURL)
        let availableID = UUID()
        let missingID = UUID()
        let available = try testAttachment(id: availableID, fileName: "file.txt")
        let unavailable = try testAttachment(id: missingID, fileName: "missing.txt")
        let mixed = Snip(content: "Text", origin: .quickEntry, attachments: [available])
        let missing = Snip(content: "Safe text", origin: .quickEntry, attachments: [unavailable])
        let snapshot = SnipLibrarySnapshot(
            snips: [mixed, missing],
            lists: [.inbox],
            attachmentURLs: [availableID: fileURL]
        )
        let model = IOSAppModel(library: ModelTestLibrary(), initialSnapshot: snapshot)
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        coordinator.copy(snips: [mixed], model: model)
        XCTAssertEqual(pasteboard.writes, [[.text("Text"), .file(fileURL)]])
        coordinator.copyText(snips: [mixed], model: model)
        XCTAssertEqual(pasteboard.writes.last, [.text("Text")])
        coordinator.copyAttachments(snips: [mixed], model: model)
        XCTAssertEqual(pasteboard.writes.last, [.file(fileURL)])
        coordinator.share(snips: [mixed], model: model)
        XCTAssertEqual(coordinator.shareRequest?.items, [.text("Text"), .file(fileURL)])

        let writeCount = pasteboard.writes.count
        coordinator.copy(snips: [missing], model: model)
        XCTAssertEqual(pasteboard.writes.count, writeCount)
        XCTAssertEqual(coordinator.unavailableFilesNotice?.payload.unavailableFileNames, ["missing.txt"])
        coordinator.copyTextFromNotice()
        XCTAssertEqual(pasteboard.writes.last, [.text("Safe text")])
        XCTAssertNil(coordinator.unavailableFilesNotice)
    }

    func testPasteboardProviderLoadsStagedBytesAfterLibrarySourceIsPruned() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapPasteboardLease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.txt")
        let expected = Data("Deferred bytes".utf8)
        try expected.write(to: sourceURL)
        let pasteboardName = UIPasteboard.Name("SnipSnapTests.\(UUID().uuidString)")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: pasteboardName, create: true))
        defer { UIPasteboard.remove(withName: pasteboardName) }
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let writer = IOSSystemPasteboard(
            pasteboard: pasteboard,
            stagingRoot: stagingRoot
        )

        XCTAssertTrue(writer.write([.text("Text"), .file(sourceURL)]))
        try FileManager.default.removeItem(at: sourceURL)
        let provider = try XCTUnwrap(pasteboard.itemProviders.last)
        let typeIdentifier = try XCTUnwrap(provider.registeredTypeIdentifiers.first)
        let loadedData = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                continuation.resume(returning: url.flatMap { try? Data(contentsOf: $0) })
            }
        }

        XCTAssertEqual(loadedData, expected)
        let leaseDirectory = try XCTUnwrap(writer.activeLeaseDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leaseDirectory.path))
        pasteboard.string = "External replacement"
        await Task.yield()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseDirectory.path))
        XCTAssertNil(writer.activeLeaseDirectory)
    }

    func testPasteboardLeaseSurvivesRelaunchOnlyWhileItsChangeCountMatches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapPasteboardReload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.txt")
        try Data("Lease".utf8).write(to: sourceURL)
        let pasteboardName = UIPasteboard.Name("SnipSnapTests.\(UUID().uuidString)")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: pasteboardName, create: true))
        defer { UIPasteboard.remove(withName: pasteboardName) }
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        var firstWriter: IOSSystemPasteboard? = IOSSystemPasteboard(
            pasteboard: pasteboard,
            stagingRoot: stagingRoot
        )
        XCTAssertTrue(firstWriter?.write([.file(sourceURL)]) == true)
        let leaseDirectory = try XCTUnwrap(firstWriter?.activeLeaseDirectory)
        firstWriter = nil

        var reloadedWriter: IOSSystemPasteboard? = IOSSystemPasteboard(
            pasteboard: pasteboard,
            stagingRoot: stagingRoot
        )
        XCTAssertEqual(reloadedWriter?.activeLeaseDirectory, leaseDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leaseDirectory.path))
        reloadedWriter = nil

        pasteboard.string = "Changed while Snip Snap was not running"
        let finalWriter = IOSSystemPasteboard(
            pasteboard: pasteboard,
            stagingRoot: stagingRoot
        )
        await Task.yield()
        XCTAssertNil(finalWriter.activeLeaseDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseDirectory.path))
    }

    func testRemovingNamedPasteboardReleasesItsFileLease() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapPasteboardRemove-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.txt")
        try Data("Remove".utf8).write(to: sourceURL)
        let pasteboardName = UIPasteboard.Name("SnipSnapTests.\(UUID().uuidString)")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: pasteboardName, create: true))
        let writer = IOSSystemPasteboard(
            pasteboard: pasteboard,
            stagingRoot: directory.appendingPathComponent("staging", isDirectory: true)
        )
        XCTAssertTrue(writer.write([.file(sourceURL)]))
        let leaseDirectory = try XCTUnwrap(writer.activeLeaseDirectory)

        UIPasteboard.remove(withName: pasteboardName)
        await Task.yield()

        XCTAssertNil(writer.activeLeaseDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseDirectory.path))
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
        XCTAssertEqual(pruneCalls, 6)
    }

    func testReloadPrunesWithNoUndoAttachmentLeases() async {
        let library = ModelTestLibrary()
        let firstModel = IOSAppModel(library: library)
        _ = await firstModel.createSnip(content: "Saved", in: SnipList.inboxID)

        let reloadedModel = IOSAppModel(library: library)
        await reloadedModel.load()

        let retentionCalls = await library.retentionCalls()
        XCTAssertEqual(retentionCalls.last, Set<UUID>())
    }

    func testUndoHistoryEvictsItsOldestAttachmentLease() throws {
        var history = IOSUndoHistory()
        var attachmentIDs: [UUID] = []
        let empty = SnipLibrarySnapshot(snips: [], lists: [.inbox])

        for index in 0...100 {
            let attachmentID = UUID()
            attachmentIDs.append(attachmentID)
            let attachment = try testAttachment(id: attachmentID, fileName: "file-\(index).txt")
            let snip = Snip(
                content: "File \(index)",
                origin: .quickEntry,
                attachments: [attachment]
            )
            let before = SnipLibrarySnapshot(snips: [snip], lists: [.inbox])
            history.record(
                name: "Delete",
                before: before,
                after: empty,
                touchedListIDs: [],
                inverse: .restore(snips: [snip]),
                selection: .init(listID: SnipList.inboxID, snipID: snip.id, snipIDs: [])
            )
        }

        XCTAssertEqual(history.retainedAttachmentIDs.count, 100)
        XCTAssertFalse(history.retainedAttachmentIDs.contains(attachmentIDs[0]))
        XCTAssertTrue(history.retainedAttachmentIDs.contains(attachmentIDs[100]))
    }

    func testDeletedSnipUndoRestoresReadableAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapUndoAttachment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.txt")
        try Data("Restore me".utf8).write(to: sourceURL)
        let library = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("snips.json"))
        let model = IOSAppModel(library: library)
        await model.load()

        let created = await model.createSnip(
            content: "",
            in: SnipList.inboxID,
            attachmentURLs: [sourceURL]
        )
        XCTAssertTrue(created)
        let snip = try XCTUnwrap(model.selectedSnip)
        let attachmentID = try XCTUnwrap(snip.attachments.first?.id)
        let storedURL = try XCTUnwrap(model.attachmentURL(for: attachmentID))
        let deleted = await model.deleteSnip(id: snip.id)
        XCTAssertTrue(deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))

        let undone = await model.undo()
        XCTAssertTrue(undone)
        let restoredURL = try XCTUnwrap(model.attachmentURL(for: attachmentID))
        XCTAssertEqual(try Data(contentsOf: restoredURL), Data("Restore me".utf8))
    }

    func testRejectedUndoReleasesDeletedSnipAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapRejectedUndo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.txt")
        try Data("Release me".utf8).write(to: sourceURL)
        let library = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("snips.json"))
        let model = IOSAppModel(library: library)
        await model.load()

        let madeList = await model.createList(name: "Work")
        XCTAssertTrue(madeList)
        let listID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        let created = await model.createSnip(
            content: "",
            in: listID,
            attachmentURLs: [sourceURL]
        )
        XCTAssertTrue(created)
        let snip = try XCTUnwrap(model.selectedSnip)
        let storedURL = try XCTUnwrap(model.attachmentURL(for: snip.attachments[0].id))
        let deleted = await model.deleteSnip(id: snip.id)
        XCTAssertTrue(deleted)
        _ = try await library.perform(.deleteList(id: listID), sortedBy: .manual)

        let undone = await model.undo()
        XCTAssertFalse(undone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    }

    func testReplacingAttachmentRetainsOldBytesUntilUndoAndThenPrunesReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapReplaceUndo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstSource = directory.appendingPathComponent("first-source.txt")
        let secondSource = directory.appendingPathComponent("second-source.txt")
        try Data("A".utf8).write(to: firstSource)
        try Data("B".utf8).write(to: secondSource)
        let library = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("snips.json"))
        let model = IOSAppModel(library: library)
        await model.load()
        let created = await model.createSnip(
            content: "Attachment",
            in: SnipList.inboxID,
            attachmentURLs: [firstSource]
        )
        XCTAssertTrue(created)
        let before = try XCTUnwrap(model.selectedSnip)
        let oldID = try XCTUnwrap(before.attachments.first?.id)
        let oldURL = try XCTUnwrap(model.attachmentURL(for: oldID))

        let edited = await model.editSnip(
            before,
            content: before.content,
            attachmentEdits: [.replacement(attachmentID: oldID, sourceURL: secondSource)]
        )
        XCTAssertTrue(edited)
        let replacementID = try XCTUnwrap(model.selectedSnip?.attachments.first?.id)
        let replacementURL = try XCTUnwrap(model.attachmentURL(for: replacementID))
        XCTAssertEqual(try Data(contentsOf: oldURL), Data("A".utf8))
        XCTAssertEqual(try Data(contentsOf: replacementURL), Data("B".utf8))

        let undone = await model.undo()
        XCTAssertTrue(undone)
        XCTAssertEqual(model.selectedSnip?.attachments.first?.id, oldID)
        XCTAssertEqual(try Data(contentsOf: oldURL), Data("A".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementURL.path))
    }

    func testUndoCapacityEvictionPrunesDeletedAttachmentBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapUndoEviction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.txt")
        try Data("Evict".utf8).write(to: source)
        let library = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("snips.json"))
        let model = IOSAppModel(library: library)
        await model.load()
        let created = await model.createSnip(
            content: "Attachment",
            in: SnipList.inboxID,
            attachmentURLs: [source]
        )
        XCTAssertTrue(created)
        let snip = try XCTUnwrap(model.selectedSnip)
        let storedURL = try XCTUnwrap(model.attachmentURL(for: snip.attachments[0].id))
        let deleted = await model.deleteSnip(id: snip.id)
        XCTAssertTrue(deleted)

        for index in 0..<99 {
            let createdList = await model.createList(name: "List \(index)")
            XCTAssertTrue(createdList)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
        let finalList = await model.createList(name: "List 99")
        XCTAssertTrue(finalList)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    }

    func testFreshModelLoadPrunesAttachmentHeldOnlyByOldMemoryUndo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapUndoReload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.txt")
        try Data("Reload".utf8).write(to: source)
        let library = try JSONSnipLibrary(fileURL: directory.appendingPathComponent("snips.json"))
        let firstModel = IOSAppModel(library: library)
        await firstModel.load()
        let created = await firstModel.createSnip(
            content: "Attachment",
            in: SnipList.inboxID,
            attachmentURLs: [source]
        )
        XCTAssertTrue(created)
        let snip = try XCTUnwrap(firstModel.selectedSnip)
        let storedURL = try XCTUnwrap(firstModel.attachmentURL(for: snip.attachments[0].id))
        let deleted = await firstModel.deleteSnip(id: snip.id)
        XCTAssertTrue(deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))

        let reloadedModel = IOSAppModel(library: library)
        await reloadedModel.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
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

    func testRecoveryReviewLoadsScopedAttentionRefreshesCurrentAndResolves() async throws {
        let namespace = ICloudSyncNamespaceBinding(
            scope: "private",
            accountLineage: "account-a",
            generation: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            zones: [ICloudSyncZoneBinding(name: "SnipSnap", ownerName: "owner-a")]
        )
        let current = Snip(content: "Current", origin: .quickEntry)
        let recoveredValue = Snip(id: UUID(), content: "Recovered", origin: .quickEntry)
        let recovered = RecoveredSnip(
            id: recoveredValue.id,
            currentSnipID: current.id,
            recovered: recoveredValue,
            conflictingFields: [.text]
        )
        let library = ModelTestLibrary(
            snips: [current],
            recovery: SnipRecoverySnapshot(pendingSnips: [recovered])
        )
        let assembly = SnipLibraryAssembly(
            library: library,
            activeCloudNamespace: namespace
        )
        XCTAssertNotNil(assembly.recoveryScope)
        let model = IOSAppModel(
            library: assembly.library,
            recoveryScope: assembly.recoveryScope
        )

        await model.load()
        XCTAssertEqual(model.needsAttentionCount, 1)
        XCTAssertEqual(model.pendingRecoveredSnips, [recovered])
        await library.replaceText("Changed while open", for: current.id)
        await model.load()
        XCTAssertEqual(model.currentSnip(for: recovered)?.content, "Changed while open")

        let resolved = await model.resolveRecovery(recovered.id, choice: .keepCurrent)
        XCTAssertTrue(resolved)
        let choices = await library.resolutionChoices()
        XCTAssertEqual(choices, [.keepCurrent])
        XCTAssertEqual(model.needsAttentionCount, 0)
    }

    func testShippedAssemblyReadsExactCloudScopeAndFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSAssemblyScopeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = ICloudSyncNamespaceBinding(
            scope: "private",
            accountLineage: "account-a",
            generation: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            zones: [ICloudSyncZoneBinding(name: "SnipSnap", ownerName: "owner-a")]
        )
        let cloudRoot = root.appendingPathComponent("Cloud", isDirectory: true)
        try writeActivationManifest(namespace: namespace, to: cloudRoot)
        let library = ModelTestLibrary()

        let cloudAssembly = SnipLibraryAssembly(
            library: library,
            syncModeRootURL: cloudRoot
        )

        XCTAssertEqual(
            SyncModeActivationManifestReader.activeCloudNamespace(
                atSyncModeRootURL: cloudRoot
            ),
            namespace
        )
        XCTAssertEqual(
            cloudAssembly.recoveryScope,
            SnipRecoveryScopeFactory.scope(forActiveCloudNamespace: namespace)
        )

        let localOnlyRoot = root.appendingPathComponent("LocalOnly", isDirectory: true)
        let localOnlyAssembly = SnipLibraryAssembly(
            library: library,
            syncModeRootURL: localOnlyRoot
        )
        XCTAssertNil(localOnlyAssembly.recoveryScope)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localOnlyRoot.path))

        let malformedRoot = root.appendingPathComponent("Malformed", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedRoot, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: malformedRoot.appendingPathComponent("activation.json")
        )
        XCTAssertNil(
            SnipLibraryAssembly(library: library, syncModeRootURL: malformedRoot).recoveryScope
        )
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

    func testSearchFiltersBulkDoneAndUndoStayAboveTheLibrarySeam() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()

        let createdAlpha = await model.createSnip(content: "Alpha note", in: SnipList.inboxID)
        XCTAssertTrue(createdAlpha)
        let alphaID = try XCTUnwrap(model.selectedSnipID)
        let createdBeta = await model.createSnip(content: "Beta task", in: SnipList.inboxID)
        XCTAssertTrue(createdBeta)
        let betaID = try XCTUnwrap(model.selectedSnipID)

        model.searchText = "alpha"
        XCTAssertEqual(model.visibleSnips.map(\.id), [alphaID])
        model.searchText = ""
        model.selectedSnipIDs = [alphaID, betaID]
        let markedDone = await model.setSelectionDone(true)
        XCTAssertTrue(markedDone)
        model.completionFilter = .done
        XCTAssertEqual(Set(model.visibleSnips.map(\.id)), [alphaID, betaID])

        _ = try await library.perform(
            .add(
                content: "Unrelated write",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date(timeIntervalSince1970: 500)
            ),
            sortedBy: .manual
        )
        let undone = await model.undo()
        XCTAssertTrue(undone)
        XCTAssertTrue(model.snips.filter { $0.id == alphaID || $0.id == betaID }.allSatisfy { !$0.isDone })
        XCTAssertTrue(model.snips.contains(where: { $0.content == "Unrelated write" }))
    }

    func testManualReorderAndBulkListMoveUseNormalRepositoryCommands() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        model.selectedListID = SnipList.inboxID
        let createdOne = await model.createSnip(content: "One", in: SnipList.inboxID)
        XCTAssertTrue(createdOne)
        let oneID = try XCTUnwrap(model.selectedSnipID)
        let createdTwo = await model.createSnip(content: "Two", in: SnipList.inboxID)
        XCTAssertTrue(createdTwo)
        let twoID = try XCTUnwrap(model.selectedSnipID)

        model.sortMode = .manual
        let reordered = await model.placeVisibleSnips([oneID, twoID])
        XCTAssertTrue(reordered)
        XCTAssertEqual(model.visibleSnips.map(\.id), [oneID, twoID])
        model.selectedSnipIDs = [oneID, twoID]
        let moved = await model.moveSelection(to: workID)
        XCTAssertTrue(moved)
        XCTAssertEqual(model.snips.filter { $0.listID == workID }.map(\.id), [oneID, twoID])

        let undone = await model.undo()
        XCTAssertTrue(undone)
        XCTAssertEqual(model.visibleSnips.map(\.id), [oneID, twoID])
    }

    func testUndoDropsAnEntryWhenItsAffectedSnipChanged() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()
        let created = await model.createSnip(content: "Original", in: SnipList.inboxID)
        XCTAssertTrue(created)
        let id = try XCTUnwrap(model.selectedSnipID)
        model.selectedSnipIDs = [id]
        let markedDone = await model.setSelectionDone(true)
        XCTAssertTrue(markedDone)
        let doneSnip = try XCTUnwrap(model.snips.first(where: { $0.id == id }))

        _ = try await library.perform(
            .update(
                id: id,
                content: "Changed elsewhere",
                attachmentURLs: nil,
                expectedUpdatedAt: doneSnip.updatedAt,
                now: Date(timeIntervalSince1970: 600)
            ),
            sortedBy: .manual
        )

        let undone = await model.undo()
        XCTAssertFalse(undone)
        XCTAssertEqual(model.undoTitle, "Undo New Snip")
        XCTAssertNotNil(model.errorMessage)
        let snapshot = await library.snapshot(sortedBy: .manual)
        XCTAssertEqual(snapshot.snips.first?.content, "Changed elsewhere")
    }

    func testSingleRowDoneAndUndoPreserveTheExistingSelection() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        await model.load()
        let madeFirst = await model.createSnip(content: "First", in: SnipList.inboxID)
        XCTAssertTrue(madeFirst)
        let firstID = try XCTUnwrap(model.selectedSnipID)
        let madeSecond = await model.createSnip(content: "Second", in: SnipList.inboxID)
        XCTAssertTrue(madeSecond)
        let secondID = try XCTUnwrap(model.selectedSnipID)
        model.selectedSnipIDs = [secondID]

        let marked = await model.toggleDone(id: firstID)
        XCTAssertTrue(marked)
        XCTAssertEqual(model.selectedSnipIDs, [secondID])

        let undone = await model.undo()
        XCTAssertTrue(undone)
        XCTAssertEqual(model.selectedSnipIDs, [secondID])
        XCTAssertEqual(model.snips.first(where: { $0.id == firstID })?.isDone, false)
    }

    func testOverlappingMutationsRunOneAtATimeAndBuildIndependentUndoEntries() async {
        let library = ModelTestLibrary(commandDelay: .milliseconds(80))
        let model = IOSAppModel(library: library)

        async let first = model.createSnip(content: "First", in: SnipList.inboxID)
        async let second = model.createSnip(content: "Second", in: SnipList.inboxID)
        let results = await (first, second)

        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        let maximumConcurrentCommands = await library.maximumConcurrentCommands()
        XCTAssertEqual(maximumConcurrentCommands, 1)
        XCTAssertEqual(model.snips.count, 2)

        let firstUndo = await model.undo()
        XCTAssertTrue(firstUndo)
        XCTAssertEqual(model.snips.count, 1)
        let secondUndo = await model.undo()
        XCTAssertTrue(secondUndo)
        XCTAssertTrue(model.snips.isEmpty)
    }

    func testUndoNewListRefusesToMoveASnipAddedElsewhere() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)

        _ = try await library.perform(
            .add(
                content: "Added elsewhere",
                origin: .quickEntry,
                source: nil,
                listID: workID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .manual
        )

        let undone = await model.undo()
        XCTAssertFalse(undone)
        let snapshot = await library.snapshot(sortedBy: .manual)
        XCTAssertTrue(snapshot.lists.contains(where: { $0.id == workID }))
        XCTAssertEqual(snapshot.snips.first?.listID, workID)
    }

    func testUndoDeletedSnipRefusesToRestoreIntoAListDeletedElsewhere() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        let createdSnip = await model.createSnip(content: "Removed", in: workID)
        XCTAssertTrue(createdSnip)
        let snipID = try XCTUnwrap(model.selectedSnipID)
        let deletedSnip = await model.deleteSnip(id: snipID)
        XCTAssertTrue(deletedSnip)

        _ = try await library.perform(.deleteList(id: workID), sortedBy: .manual)

        let undone = await model.undo()
        XCTAssertFalse(undone)
        let snapshot = await library.snapshot(sortedBy: .manual)
        XCTAssertFalse(snapshot.snips.contains(where: { $0.id == snipID }))
        XCTAssertFalse(snapshot.lists.contains(where: { $0.id == workID }))
    }

    func testUndoRenameDropsStaleEntryWhenTheOldNameWasTakenElsewhere() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let work = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" }))
        let renamedList = await model.renameList(work, name: "Focus")
        XCTAssertTrue(renamedList)
        _ = try await library.perform(
            .createList(name: "Work", systemImage: "list.bullet"),
            sortedBy: .manual
        )

        let undone = await model.undo()

        XCTAssertFalse(undone)
        XCTAssertEqual(model.undoTitle, "Undo New List")
        XCTAssertNotNil(model.errorMessage)
    }

    func testUndoDeletedListDropsStaleEntryWhenItsNameWasTakenElsewhere() async throws {
        let library = ModelTestLibrary()
        let model = IOSAppModel(library: library)
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let work = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" }))
        let deletedList = await model.deleteList(id: work.id)
        XCTAssertTrue(deletedList)
        _ = try await library.perform(
            .createList(name: "Work", systemImage: "list.bullet"),
            sortedBy: .manual
        )

        let undone = await model.undo()

        XCTAssertFalse(undone)
        XCTAssertEqual(model.undoTitle, "Undo New List")
        XCTAssertNotNil(model.errorMessage)
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

private func writeActivationManifest(
    namespace: ICloudSyncNamespaceBinding,
    to rootURL: URL
) throws {
    let storeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let namespaceData = try JSONEncoder().encode(namespace)
    let namespaceValue = try JSONSerialization.jsonObject(with: namespaceData)
    let manifest: [String: Any] = [
        "version": 2,
        "activeStoreID": storeID.uuidString,
        "stores": [[
            "id": storeID.uuidString,
            "kind": "iCloudSync",
            "namespace": namespaceValue,
            "relativeRoot": "stores/iCloudSync-\(storeID.uuidString.lowercased())",
            "syncProtocol": "fullRecordV1",
            "revision": 0,
            "lifecycle": "ready"
        ]]
    ]
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(
        to: rootURL.appendingPathComponent("activation.json")
    )
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

@MainActor
private final class RecordingPasteboard: IOSPasteboardWriting {
    private(set) var writes: [[IOSCopyItem]] = []

    func write(_ items: [IOSCopyItem]) -> Bool {
        writes.append(items)
        return true
    }
}

private func testAttachment(id: UUID, fileName: String) throws -> SnipAttachment {
    let json = """
    {
      "id": "\(id.uuidString)",
      "fileName": "\(fileName)",
      "relativePath": "\(id.uuidString)/\(fileName)",
      "contentType": "public.text",
      "byteCount": 1
    }
    """
    return try JSONDecoder().decode(SnipAttachment.self, from: Data(json.utf8))
}

private actor ModelTestLibrary: SnipLibrary {
    private var snips: [Snip]
    private var lists: [SnipList] = [.inbox]
    private let attachmentURLs: [UUID: URL]
    private(set) var lastAddedAttachmentURLs: [URL] = []
    private(set) var lastAttachmentEdit: (snipID: UUID, content: String, edits: [SnipAttachmentEdit])?
    private var attachmentPruneCalls = 0
    private var recovery: SnipRecoverySnapshot
    private var resolvedChoices: [SnipRecoveryChoice] = []
    private var attachmentRetentionCalls: [Set<UUID>] = []
    private let commandDelay: Duration?
    private var activeCommandCount = 0
    private var maximumActiveCommandCount = 0

    init(
        snips: [Snip] = [],
        recovery: SnipRecoverySnapshot = .empty,
        attachmentURLs: [UUID: URL] = [:],
        commandDelay: Duration? = nil
    ) {
        self.snips = snips
        self.recovery = recovery
        self.attachmentURLs = attachmentURLs
        self.commandDelay = commandDelay
    }

    func addedAttachmentURLs() -> [URL] {
        lastAddedAttachmentURLs
    }

    func pruneCalls() -> Int {
        attachmentPruneCalls
    }

    func replaceText(_ text: String, for id: UUID) {
        guard let index = snips.firstIndex(where: { $0.id == id }) else { return }
        snips[index].content = text
    }

    func resolutionChoices() -> [SnipRecoveryChoice] {
        resolvedChoices
    }

    func recoverySnapshot(in scope: SnipRecoveryScope) -> SnipRecoverySnapshot {
        _ = scope
        return recovery
    }

    func resolveRecovery(
        _ id: UUID,
        in scope: SnipRecoveryScope,
        choice: SnipRecoveryChoice
    ) throws -> SnipLibrarySnapshot {
        _ = scope
        guard recovery.pendingSnips.contains(where: { $0.id == id })
            || recovery.pendingLists.contains(where: { $0.id == id })
        else { throw SnipLibraryError.recoveryNotFound }
        resolvedChoices.append(choice)
        recovery = .empty
        return makeSnapshot(sortMode: .chronological)
    }

    func retentionCalls() -> [Set<UUID>] {
        attachmentRetentionCalls
    }

    func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        makeSnapshot(sortMode: sortMode)
    }

    func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate {
        activeCommandCount += 1
        maximumActiveCommandCount = max(maximumActiveCommandCount, activeCommandCount)
        defer { activeCommandCount -= 1 }
        if let commandDelay { try? await Task.sleep(for: commandDelay) }
        let outcome = try apply(command)
        return SnipLibraryUpdate(snapshot: makeSnapshot(sortMode: sortMode), outcome: outcome)
    }

    func maximumConcurrentCommands() -> Int {
        maximumActiveCommandCount
    }

    private func apply(_ command: SnipLibraryCommand) throws -> SnipLibraryOutcome {
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
                listID: listID,
                manualPosition: nextTopPosition(in: listID)
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
        case .pruneAttachments(let retainedIDs):
            attachmentPruneCalls += 1
            attachmentRetentionCalls.append(retainedIDs)
            outcome = .none
        case .restore(let restored):
            let existing = Set(snips.map(\.id))
            snips.append(contentsOf: restored.filter { !existing.contains($0.id) })
            outcome = .none
        case .setDone(let ids, let done):
            for index in snips.indices where ids.contains(snips[index].id) {
                snips[index].isDone = done
                snips[index].updatedAt = Date()
            }
            outcome = .none
        case .place(let ids, let listID, let destinationID, let sortMode):
            let moving = Set(ids)
            var destination = Snip.sorted(
                snips.filter { $0.listID == listID && !moving.contains($0.id) },
                by: sortMode
            ).map(\.id)
            let insertion = destinationID.flatMap(destination.firstIndex) ?? destination.endIndex
            destination.insert(contentsOf: ids, at: insertion)
            let sourceLists = Set(snips.filter { moving.contains($0.id) }.map(\.listID))
            for index in snips.indices where moving.contains(snips[index].id) {
                snips[index].listID = listID
            }
            reindex(listID: listID, orderedIDs: destination)
            for sourceList in sourceLists where sourceList != listID { reindex(listID: sourceList) }
            outcome = .none
        case .moveChronologically(let ids, let listID):
            for index in snips.indices where ids.contains(snips[index].id) {
                snips[index].listID = listID
                snips[index].manualPosition = nextTopPosition(in: listID, excluding: Set(ids))
            }
            outcome = .none
        case .createList(let name, let systemImage):
            guard !lists.contains(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { throw SnipLibraryError.duplicateList }
            let list = SnipList(
                id: UUID(),
                name: name,
                systemImage: systemImage,
                position: lists.count
            )
            lists.append(list)
            outcome = .listCreated(list)
        case .restoreList(let list):
            guard !lists.contains(where: { $0.id == list.id }),
                !lists.contains(where: {
                    $0.name.caseInsensitiveCompare(list.name) == .orderedSame
                })
            else { throw SnipLibraryError.invalidList }
            for index in lists.indices where lists[index].position >= list.position {
                lists[index].position += 1
            }
            lists.append(list)
            outcome = .none
        case .updateList(let id, let name, let systemImage):
            guard let index = lists.firstIndex(where: { $0.id == id }) else {
                throw SnipLibraryError.invalidList
            }
            guard !lists.contains(where: {
                $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { throw SnipLibraryError.duplicateList }
            lists[index].name = name
            lists[index].systemImage = systemImage
            outcome = .none
        case .deleteList(let id):
            lists.removeAll { $0.id == id }
            for index in snips.indices where snips[index].listID == id {
                snips[index].listID = SnipList.inboxID
            }
            for index in lists.indices { lists[index].position = index }
            outcome = .none
        case .batch(let commands):
            var last: SnipLibraryOutcome = .none
            for command in commands {
                let next = try apply(command)
                if next != .none { last = next }
            }
            outcome = last
        case .guarded(let expectation, let command):
            let snipsByID = Dictionary(uniqueKeysWithValues: snips.map { ($0.id, $0) })
            let listsByID = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0) })
            guard expectation.expectedSnips.allSatisfy({ snipsByID[$0.id] == $0 }),
                expectation.absentSnipIDs.allSatisfy({ snipsByID[$0] == nil }),
                expectation.expectedLists.allSatisfy({ listsByID[$0.id] == $0 }),
                expectation.absentListIDs.allSatisfy({ listsByID[$0] == nil }),
                expectation.requiredListIDs.allSatisfy({ listsByID[$0] != nil }),
                expectation.expectedListMemberships.allSatisfy({ listID, expectedIDs in
                    listsByID[listID] != nil
                        && Set(snips.lazy.filter { $0.listID == listID }.map(\.id)) == expectedIDs
                })
            else { throw SnipLibraryError.snipChanged }
            outcome = try apply(command)
        default:
            outcome = .none
        }
        return outcome
    }

    private func makeSnapshot(sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        SnipLibrarySnapshot(
            snips: lists.sorted { $0.position < $1.position }.flatMap { list in
                Snip.sorted(snips.filter { $0.listID == list.id }, by: sortMode)
            },
            lists: lists.sorted { $0.position < $1.position },
            attachmentURLs: attachmentURLs
        )
    }

    private func nextTopPosition(in listID: UUID, excluding: Set<UUID> = []) -> Int64 {
        (snips.filter { $0.listID == listID && !excluding.contains($0.id) }
            .map(\.manualPosition).min() ?? 1) - 1
    }

    private func reindex(listID: UUID, orderedIDs: [UUID]? = nil) {
        let ids = orderedIDs ?? Snip.sorted(
            snips.filter { $0.listID == listID },
            by: .manual
        ).map(\.id)
        for (position, id) in ids.enumerated() {
            guard let index = snips.firstIndex(where: { $0.id == id }) else { continue }
            snips[index].manualPosition = Int64(position)
        }
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
