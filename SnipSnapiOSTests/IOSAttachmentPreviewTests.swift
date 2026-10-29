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
final class IOSAttachmentPreviewTests: IOSModelTestCase {
    func testPreviewPreparationRejectsPageAndSearchChangesWhileWaiting() async {
        for change in 0..<3 {
            let id = UUID()
            let handler = IOSCloudSyncHandlerProbe(states: [id: .waiting])
            let model = IOSAppModel(library: ModelTestLibrary(), cloudSyncHandler: handler)
            await model.load()
            let preparing = Task { await model.prepareAttachmentPreview(id) }
            await handler.waitUntilPrepareStarts()
            switch change {
            case 0:
                model.selectPage(.clipboard)
            case 1:
                model.selectPage(.clipboard)
                model.selectPage(.list(SnipList.inboxID))
            default:
                model.isSearchPresented = true
                model.isSearchPresented = false
            }
            await handler.finishPrepare(with: .success(URL(fileURLWithPath: "/tmp/stale-preview.txt")))
            let preview = await preparing.value
            XCTAssertNil(preview, "A completed download must not revive its former presentation")
        }
    }

    func testPreviewFailureOnlyPresentsForItsCurrentPageAndSearchOwner() async {
        for change in 0..<6 {
            let id = UUID()
            let handler = IOSCloudSyncHandlerProbe(states: [id: .waiting])
            let diagnostics = IOSDiagnosticRecorderProbe()
            let model = IOSAppModel(library: ModelTestLibrary(), cloudSyncHandler: handler,
                diagnostics: diagnostics.recorder)
            await model.load()
            if change == 3 || change == 4 { model.isSearchPresented = true }
            let preparing = Task { await model.prepareAttachmentPreview(id) }
            await handler.waitUntilPrepareStarts()
            switch change {
            case 1, 5:
                model.selectPage(.clipboard)
            case 2:
                model.selectPage(.clipboard)
                model.selectPage(.list(SnipList.inboxID))
            case 3:
                model.isSearchPresented = false
            case 4:
                model.isSearchPresented = false
                model.isSearchPresented = true
            default:
                break
            }
            if change == 5 { model.errorMessage = "Newer action failed" }
            await handler.finishPrepare(with: .failure(SnipLibraryError.attachmentCopyFailed))
            let preview = await preparing.value
            XCTAssertNil(preview)
            if change == 0 {
                XCTAssertNotNil(model.errorMessage, "The current request still needs its failure alert")
            } else if change == 5 {
                XCTAssertEqual(model.errorMessage, "Newer action failed")
            } else {
                XCTAssertNil(model.errorMessage, "A stale preview must not interrupt the current screen")
            }
            XCTAssertEqual(diagnostics.events.count, 1)
            XCTAssertEqual(diagnostics.events.first?.operation, "attachment.prepare")
            XCTAssertEqual(diagnostics.events.first?.visibility, change == 0 ? .user : .background)
        }
    }

    func testClipboardCopyFeedbackDeadlineStartsAtLatestCopyWithoutAPresenter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferencesName = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: preferencesName))
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let clipboard = IOSClipboardModel(rootURL: root,
            settings: SyncedContentSettingsModel(mode: .localOnly), preferences: preferences)
        let model = IOSAppModel(library: ModelTestLibrary())
        let coordinator = IOSCopyShareCoordinator()
        let entry = ClipboardEntry(items: [ClipboardPayloadItem(representations: [
            ClipboardRepresentation(type: UTType.utf8PlainText.identifier, data: Data("Feedback".utf8))
        ])])

        let firstSucceeded = await coordinator.copyClipboardEntry(entry, clipboard: clipboard, model: model).value
        XCTAssertTrue(firstSucceeded)
        let first = try XCTUnwrap(model.toast)
        let secondStarted = ContinuousClock().now
        let secondSucceeded = await coordinator.copyClipboardEntry(entry, clipboard: clipboard, model: model).value
        let secondFinished = ContinuousClock().now
        XCTAssertTrue(secondSucceeded)
        let latest = try XCTUnwrap(model.toast)

        XCTAssertNotEqual(first.id, latest.id)
        XCTAssertEqual(latest.message, "Snapped")
        XCTAssertEqual(latest.detail, "Copied to clipboard")
        XCTAssertNil(latest.action)
        XCTAssertEqual(latest.duration, .seconds(3))
        XCTAssertGreaterThanOrEqual(latest.expiresAt, secondStarted.advanced(by: latest.duration))
        XCTAssertLessThanOrEqual(latest.expiresAt, secondFinished.advanced(by: latest.duration))
        XCTAssertGreaterThan(latest.expiresAt, first.expiresAt,
                             "The first copy must not consume the second copy's feedback lifetime")
        // The shared presenter consumes this fixed deadline even after its source view is hidden.
        try await ContinuousClock().sleep(until: latest.expiresAt)
        XCTAssertGreaterThanOrEqual(ContinuousClock().now, latest.expiresAt)
        XCTAssertEqual(model.toast?.expiresAt, latest.expiresAt,
                       "Without a presenter, retaining feedback must not renew its expired deadline")
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
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(
            library: ModelTestLibrary(),
            cloudSyncHandler: handler,
            diagnostics: diagnostics.recorder
        )
        await model.load()
        let preparing = Task { await model.prepareAttachment(id, for: .open) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .failure(SnipLibraryError.attachmentCopyFailed))
        let preparedURL = await preparing.value
        XCTAssertNil(preparedURL)
        XCTAssertEqual(model.attachmentTransferState(for: id), .failed)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(
            diagnostics.events,
            [.failure(
                operation: "attachment.prepare",
                error: SnipLibraryError.attachmentCopyFailed,
                visibility: .user
            )]
        )
    }

    func testCachePreflightAttachmentFailureRecordsOneTerminalEvent() async {
        let id = UUID()
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(
            library: ModelTestLibrary(),
            cloudSyncHandler: handler,
            diagnostics: diagnostics.recorder
        )
        await model.load()
        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .failure(IOSCachePreflightFailure.pathOutsideRoot))

        let preparedURL = await preparing.value
        XCTAssertNil(preparedURL)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, "attachment.prepare")
        XCTAssertEqual(diagnostics.events.first?.outcome, .failed)
        XCTAssertEqual(diagnostics.events.first?.errorCode, "storage.pathOutsideRoot")
    }

    func testPassiveAttachmentFailureDoesNotShowAnAlert() async {
        let id = UUID()
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(
            library: ModelTestLibrary(),
            cloudSyncHandler: handler,
            diagnostics: diagnostics.recorder
        )
        await model.load()
        let preparing = Task {
            await model.prepareAttachment(id, for: .preview, showsFailureAlert: false)
        }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .failure(SnipLibraryError.attachmentCopyFailed))

        let preparedURL = await preparing.value
        XCTAssertNil(preparedURL)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.attachmentTransferState(for: id), .failed)
        XCTAssertEqual(diagnostics.events, [.failure(
            operation: "attachment.prepare",
            error: SnipLibraryError.attachmentCopyFailed,
            visibility: .background
        )])
    }

    func testRepeatedPreviewFailureRecordsOneEventWhileAlertIsVisible() async {
        let id = UUID()
        let handler = IOSCopyShareActionHandlerProbe(
            states: [id: .waiting],
            results: Array(repeating: .failure(SnipLibraryError.attachmentCopyFailed), count: 3)
        )
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(
            library: ModelTestLibrary(),
            cloudSyncHandler: handler,
            diagnostics: diagnostics.recorder
        )
        await model.load()

        _ = await model.prepareAttachment(id, for: .preview)
        _ = await model.prepareAttachment(id, for: .preview)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(diagnostics.events.count, 1)

        model.errorMessage = nil
        _ = await model.prepareAttachment(id, for: .preview)
        XCTAssertEqual(diagnostics.events.count, 2)
    }

    func testCancelledAttachmentPreparationShowsNoErrorOrFailureEvent() async {
        let id = UUID()
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(
            library: ModelTestLibrary(),
            cloudSyncHandler: handler,
            diagnostics: diagnostics.recorder
        )
        await model.load()
        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .failure(CancellationError()))

        let preparedURL = await preparing.value
        XCTAssertNil(preparedURL)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.attachmentTransferState(for: id), .available)
        XCTAssertTrue(diagnostics.events.isEmpty)
    }

    func testCancelledAutomaticPreparationDoesNotUndoConcurrentPreviewSuccess() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapConcurrentPrepare-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: url)
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let model = IOSAppModel(library: ModelTestLibrary(), cloudSyncHandler: handler)
        await model.load()

        let automatic = Task {
            await model.prepareAttachment(id, for: .preview, showsFailureAlert: false)
        }
        await handler.waitUntilPrepareCount(1)
        let explicit = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareCount(2)
        await handler.finishPrepare(with: .success(url), at: 1)
        let explicitURL = await explicit.value
        XCTAssertEqual(explicitURL, url)
        await handler.finishPrepare(with: .failure(CancellationError()))
        let automaticURL = await automatic.value
        XCTAssertNil(automaticURL)
        XCTAssertEqual(model.attachmentTransferState(for: id), .available)

        try FileManager.default.removeItem(at: url)
        XCTAssertNil(model.usableAttachmentURL(for: id))
        XCTAssertEqual(model.attachmentTransferState(for: id), .available)
        let retry = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareCount(3)
        try Data([4, 5, 6]).write(to: url)
        await handler.finishPrepare(with: .success(url))
        let retryURL = await retry.value
        XCTAssertEqual(retryURL, url)
    }

    func testCancelledAutomaticPreparationKeepsNewCloudStateAfterTransportError() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapCancelledPrepareRetry-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: url)
        let handler = IOSCloudSyncHandlerProbe(states: [id: .waiting])
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(
            library: ModelTestLibrary(), cloudSyncHandler: handler,
            diagnostics: diagnostics.recorder
        )
        await model.load()

        let automatic = Task {
            await model.prepareAttachment(id, for: .preview, showsFailureAlert: false)
        }
        await handler.waitUntilPrepareStarts()
        await handler.setState(.available, for: id)
        await model.load()
        XCTAssertEqual(model.attachmentTransferState(for: id), .available)

        automatic.cancel()
        await handler.finishPrepare(with: .failure(SnipLibraryError.attachmentCopyFailed))
        let automaticURL = await automatic.value
        XCTAssertNil(automaticURL)
        XCTAssertEqual(model.attachmentTransferState(for: id), .available)
        XCTAssertTrue(diagnostics.events.isEmpty)

        let retry = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareCount(2)
        await handler.finishPrepare(with: .success(url))
        let retryURL = await retry.value
        XCTAssertEqual(retryURL, url)
    }

    func testUsableAttachmentURLRejectsAStaleFile() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapUsableAttachmentTest-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: url)
        let model = IOSAppModel(library: ModelTestLibrary(attachmentURLs: [id: url]))
        await model.load()

        XCTAssertEqual(model.usableAttachmentURL(for: id), url)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(model.attachmentURL(for: id), url)
        XCTAssertNil(model.usableAttachmentURL(for: id))
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

    func testRefreshingTheLibraryKeepsAVerifiedImageFile() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapVerifiedImageRefresh-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: url)
        let attachment = try testAttachment(id: id, fileName: "photo.png")
        let snip = Snip(content: "Photo", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip], attachmentURLs: [id: url]),
            cloudSyncHandler: handler
        )
        await model.load()

        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .success(url))
        let preparedURL = await preparing.value
        XCTAssertEqual(preparedURL, url)

        await model.load()

        XCTAssertEqual(model.usableAttachmentURL(for: id), url)
        XCTAssertEqual(model.attachmentTransferState(for: id), .available)
        let prepareCount = await handler.prepareCount()
        XCTAssertEqual(prepareCount, 1)
    }

    func testRefreshingTheLibraryKeepsAVerifiedImageFileWhileItIsStillSyncing() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapVerifiedImageSyncing-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: url)
        let attachment = try testAttachment(id: id, fileName: "photo.png")
        let snip = Snip(content: "Photo", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip], attachmentURLs: [id: url]),
            cloudSyncHandler: handler
        )
        await model.load()
        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .success(url))
        _ = await preparing.value

        await handler.setState(.waiting, for: id)
        await model.load()
        XCTAssertEqual(model.usableAttachmentURL(for: id), url)
        XCTAssertEqual(model.attachmentTransferState(for: id), .waiting)

        await handler.setState(.syncing, for: id)
        await model.load()
        XCTAssertEqual(model.usableAttachmentURL(for: id), url)
        XCTAssertEqual(model.attachmentTransferState(for: id), .syncing)
    }

    func testRefreshingTheLibraryDropsAVerifiedImageFileWhenSyncFails() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapVerifiedImageFailed-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: url)
        let attachment = try testAttachment(id: id, fileName: "photo.png")
        let snip = Snip(content: "Photo", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip], attachmentURLs: [id: url]),
            cloudSyncHandler: handler
        )
        await model.load()
        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .success(url))
        _ = await preparing.value

        await handler.setState(.failed, for: id)
        await model.load()

        XCTAssertEqual(model.attachmentTransferState(for: id), .failed)
        XCTAssertNil(model.usableAttachmentURL(for: id))
    }

    func testClearingDownloadsDropsAFilePreparedWhileTheLibraryReloads() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapVerifiedImageClear-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: url)
        let attachment = try testAttachment(id: id, fileName: "photo.png")
        let snip = Snip(content: "Photo", origin: .quickEntry, attachments: [attachment])
        let library = ModelTestLibrary(snips: [snip], attachmentURLs: [id: url])
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let model = IOSAppModel(library: library, cloudSyncHandler: handler)
        await model.load()

        await library.suspendNextSnapshot()
        let clearing = Task { await model.clearDownloadedFiles() }
        await library.waitUntilSnapshotStarts()
        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .success(url))
        _ = await preparing.value
        await library.resumeSnapshot()
        await clearing.value

        XCTAssertNil(model.attachmentURL(for: id))
        XCTAssertNil(model.usableAttachmentURL(for: id))
    }

    func testRefreshingTheLibraryDropsAVerifiedImageFileThatWasRemoved() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapVerifiedImageRemoved-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: url)
        let attachment = try testAttachment(id: id, fileName: "photo.png")
        let snip = Snip(content: "Photo", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip], attachmentURLs: [id: url]),
            cloudSyncHandler: handler
        )
        await model.load()

        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .success(url))
        _ = await preparing.value
        try FileManager.default.removeItem(at: url)

        await model.load()

        XCTAssertNil(model.usableAttachmentURL(for: id))
    }

    func testRefreshingTheLibraryDropsAVerifiedImageFileWhenTheAttachmentChanges() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapVerifiedImageReplaced-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: url)
        let snip = Snip(
            content: "Photo",
            origin: .quickEntry,
            attachments: [try testAttachment(id: id, fileName: "photo.png")]
        )
        let library = ModelTestLibrary(snips: [snip], attachmentURLs: [id: url])
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let model = IOSAppModel(library: library, cloudSyncHandler: handler)
        await model.load()
        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .success(url))
        _ = await preparing.value

        await library.replaceAttachments(
            [try testAttachment(id: id, fileName: "photo.png", byteCount: 99)],
            on: snip.id
        )
        await model.load()

        XCTAssertNil(model.usableAttachmentURL(for: id))
    }

    func testPrepareDoesNotKeepAnImageFileWhenTheAttachmentChangesDuringDownload() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapVerifiedImageMidDownload-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: url)
        let snip = Snip(
            content: "Photo",
            origin: .quickEntry,
            attachments: [try testAttachment(id: id, fileName: "photo.png")]
        )
        let library = ModelTestLibrary(snips: [snip], attachmentURLs: [id: url])
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let model = IOSAppModel(library: library, cloudSyncHandler: handler)
        await model.load()

        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await library.replaceAttachments(
            [try testAttachment(id: id, fileName: "photo.png", byteCount: 99)],
            on: snip.id
        )
        await model.load()
        await handler.finishPrepare(with: .success(url))
        let prepared = await preparing.value

        XCTAssertNil(prepared)
        XCTAssertNil(model.attachmentURL(for: id))
        XCTAssertNil(model.usableAttachmentURL(for: id))
    }

    func testRefreshingTheLibraryDropsAVerifiedImageFileReplacedByASymbolicLink() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnipSnapVerifiedImageSymlink-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("photo.png")
        let other = root.appendingPathComponent("other.png")
        try Data([1, 2, 3]).write(to: url)
        try Data([4, 5, 6]).write(to: other)
        let snip = Snip(
            content: "Photo",
            origin: .quickEntry,
            attachments: [try testAttachment(id: id, fileName: "photo.png")]
        )
        let handler = IOSCloudSyncHandlerProbe(states: [id: .available])
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip], attachmentURLs: [id: url]),
            cloudSyncHandler: handler
        )
        await model.load()
        let preparing = Task { await model.prepareAttachment(id, for: .preview) }
        await handler.waitUntilPrepareStarts()
        await handler.finishPrepare(with: .success(url))
        _ = await preparing.value
        await model.load()
        _ = model.usableAttachmentURL(for: id)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        await model.load()

        XCTAssertNil(model.usableAttachmentURL(for: id))
    }

    func testLocalAttachmentStaysUsableWhenCloudHandlerHasNoSyncedState() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSInactiveLocalAttachment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let local = root.appendingPathComponent("local.txt")
        try Data("Available local attachment".utf8).write(to: local)
        let handler = IOSCloudSyncHandlerProbe(states: [:], isActive: false)
        let model = IOSAppModel(
            library: ModelTestLibrary(attachmentURLs: [id: local]),
            cloudSyncHandler: handler
        )

        await model.load()

        XCTAssertEqual(model.attachmentURL(for: id), local)
        XCTAssertFalse(model.isCloudSyncActive)
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
        XCTAssertFalse(model.isCloudSyncActive)
    }

    func testNewOfflineAttachmentStaysUsableUntilSyncPublishesIt() async throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSNewLocalAttachment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let local = root.appendingPathComponent("local.txt")
        try Data("Available local attachment".utf8).write(to: local)
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

    func testUnknownICloudSyncModeNeverExposesAnUnverifiedLocalURL() async {
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

    func testManualRetryWaitsForCheckedWorkAndRejectsOverlap() async {
        let library = ModelTestLibrary()
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .syncCompleted,
            activeLibrary: library,
            pausesCloudWork: true
        )
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let session = IOSAppSession(
            library: library,
            syncedContentSettings: settings,
            cloudSyncSession: cloudSession
        )
        settings.recordSyncFailure(.retryingSoon)
        let first = Task { await session.retrySyncWhenPossible() }
        await cloudSession.waitUntilCloudWorkStarts()

        XCTAssertFalse(settings.canSyncNow)
        XCTAssertEqual(settings.state, .failed(.retryingSoon))
        await session.retrySyncWhenPossible()
        let retryCount = await cloudSession.retryCount()
        let syncCount = await cloudSession.syncCount()
        let scheduleCount = await cloudSession.scheduleCount()
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(syncCount, 0)
        XCTAssertEqual(scheduleCount, 0)

        await cloudSession.resumeCloudWork()
        await first.value
        XCTAssertTrue(settings.canSyncNow)
        XCTAssertEqual(settings.state, .ready)
    }

    func testImagePreviewEligibilityUsesContentTypeAndChecksUnknownFiles() {
        XCTAssertFalse(AttachmentImageType.isImage(
            fileName: "image-without-extension", contentType: UTType.data.identifier
        ))
        XCTAssertFalse(AttachmentImageType.isImage(
            fileName: "image-without-extension", contentType: nil
        ))
        XCTAssertTrue(AttachmentImageType.isImage(
            fileName: "image-without-extension", contentType: UTType.png.identifier
        ))
        XCTAssertFalse(AttachmentImageType.isImage(
            fileName: "notes", contentType: UTType.plainText.identifier
        ))
        XCTAssertFalse(AttachmentImageType.isImage(
            fileName: "notes.txt", contentType: nil
        ))
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
}
