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
final class IOSSnipCopyTests: IOSModelTestCase {
    func testSecondCopyUsesLocalBytesWhileEarlierStatusReadsAreHeld() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("local.txt")
        try Data("Locally readable bytes".utf8).write(to: file)
        let attachment = try testAttachment(id: UUID(), fileName: "local.txt")
        let first = Snip(content: "First copy", origin: .quickEntry)
        let second = Snip(content: "Second copy", origin: .quickEntry, attachments: [attachment])
        let library = ModelTestLibrary(snips: [first, second], attachmentURLs: [attachment.id: file])
        let handler = HeldAttachmentStatusHandler()
        let model = IOSAppModel(library: library, cloudSyncHandler: handler)
        await model.load()
        await handler.holdNextRead(queuesActiveReads: true)
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
        var firstResult: Bool?
        let firstCopy = Task { firstResult = await coordinator.copy(snips: [first], model: model) }
        let held = await TestReadiness.wait(timeout: 2) { await handler.isReadHeld }
        XCTAssertTrue(held)
        let firstFinished = await TestReadiness.wait(timeout: 2) { firstResult != nil }
        XCTAssertTrue(firstFinished)
        guard firstFinished else {
            await handler.releaseRead()
            await firstCopy.value
            return
        }
        XCTAssertEqual(firstResult, true)
        var sent: Bool?
        let sending = Task { sent = await model.createSnip(content: "Another local action", in: SnipList.inboxID) }
        let sendFinished = await TestReadiness.wait(timeout: 2) { sent != nil }
        XCTAssertTrue(sendFinished)
        guard sendFinished else {
            await handler.releaseRead()
            await sending.value
            return
        }
        XCTAssertEqual(sent, true)
        let queued = await TestReadiness.wait(timeout: 2) { await handler.isActiveReadHeld }
        XCTAssertTrue(queued)
        var result: Bool?
        let copying = Task { result = await coordinator.copy(snips: [second], model: model) }
        let finished = await TestReadiness.wait(timeout: 2) { result != nil }
        XCTAssertTrue(finished, "Same-owner local files must not wait behind presentation reads")
        XCTAssertEqual(result, true)
        let prepares = await handler.prepareCount
        XCTAssertEqual(prepares, 0, "Already trusted local files need no cloud file operation")
        XCTAssertEqual(pasteboard.writes.last, [.text("Second copy"), .file(file)])
        await handler.releaseRead()
        await copying.value
    }

    func testMultiAttachmentCopyAllowsOrdinarySameSourceDeletionOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFile = root.appendingPathComponent("first.txt")
        let secondFile = root.appendingPathComponent("second.txt")
        try Data("old!".utf8).write(to: firstFile)
        try Data("two!".utf8).write(to: secondFile)
        let store = root.appendingPathComponent("snips.json")
        let library = try JSONSnipLibrary(fileURL: store)
        _ = try await library.perform(.add(content: "Original captured text", origin: .quickEntry, source: nil,
            listID: SnipList.inboxID, attachmentURLs: [firstFile, secondFile], requestID: UUID(), now: Date()),
            sortedBy: .manual)
        let initial = try await library.checkedSnapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(initial.snips.first)
        let attachments = snip.attachments
        let handler = IOSCloudSyncHandlerProbe(states: Dictionary(uniqueKeysWithValues:
            attachments.map { ($0.id, .waiting) }))
        let model = IOSAppModel(library: library, cloudSyncHandler: handler)
        await model.load()
        let name = UIPasteboard.Name("SnipSnap-two-file-\(UUID())")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let writer = IOSSystemPasteboard(pasteboard: pasteboard, stagingRoot: root.appendingPathComponent("Clipboard"))
        let coordinator = IOSCopyShareCoordinator(pasteboard: writer)
        let copying = Task { await coordinator.copy(snips: [snip], model: model) }
        let firstStarted = await TestReadiness.wait(timeout: 2) { await handler.prepareCount() == 1 }
        XCTAssertTrue(firstStarted)
        await handler.finishPrepare(with: .success(firstFile))
        let secondStarted = await TestReadiness.wait(timeout: 2) { await handler.prepareCount() == 2 }
        XCTAssertTrue(secondStarted)
        let deleted = await model.deleteSnip(id: snip.id)
        XCTAssertTrue(deleted)
        let undo = try XCTUnwrap(model.toast)
        XCTAssertEqual(undo.action, .undoDelete)
        await handler.finishPrepare(with: .success(secondFile))
        let copied = await copying.value
        XCTAssertTrue(copied)
        XCTAssertEqual(pasteboard.string, "Original captured text")
        XCTAssertEqual(pasteboard.itemProviders.count, 3)
        var received: [Data?] = []
        for provider in pasteboard.itemProviders.dropFirst() {
            let type = try XCTUnwrap(provider.registeredTypeIdentifiers.first)
            let loaded: (Data?, String?) = await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    do {
                        let data = try url.map { try Data(contentsOf: $0) }
                        continuation.resume(returning: (data, error.map { String(describing: $0) }))
                    } catch {
                        continuation.resume(returning: (nil, String(describing: error)))
                    }
                }
            }
            XCTAssertNil(loaded.1, "Provider \(type) failed: \(loaded.1 ?? "none")")
            received.append(loaded.0)
        }
        XCTAssertEqual(received, [Data("old!".utf8), Data("two!".utf8)])
        XCTAssertEqual(model.toast?.id, undo.id)
        XCTAssertEqual(model.toast?.action, .undoDelete)
        XCTAssertTrue(model.snips.isEmpty)
        XCTAssertTrue(model.attachmentURLs.isEmpty)
        for attachment in attachments {
            XCTAssertNil(model.attachmentURL(for: attachment.id))
            XCTAssertEqual(model.attachmentTransferState(for: attachment.id), .waiting)
        }
        let saved = try await JSONSnipLibrary(fileURL: store).checkedSnapshot(sortedBy: .manual)
        XCTAssertTrue(saved.snips.isEmpty)
        XCTAssertTrue(saved.attachmentURLs.isEmpty)
    }

    func testDeletedSnipDoesNotRegisterItsNextCapturedPreparation() async throws {
        for use in [SyncedAttachmentUse.copy, .export] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let files = [root.appendingPathComponent("first.txt"), root.appendingPathComponent("second.txt")]
            let bytes = [Data("old!".utf8), Data("two!".utf8)]
            for (file, data) in zip(files, bytes) { try data.write(to: file) }
            let attachments = try [testAttachment(id: UUID(), fileName: "first.txt", byteCount: 4),
                                   testAttachment(id: UUID(), fileName: "second.txt", byteCount: 4)]
            let snip = Snip(content: "Captured text", origin: .quickEntry, attachments: attachments)
            let library = ModelTestLibrary(snips: [snip])
            let handler = IOSCloudSyncHandlerProbe(states: Dictionary(uniqueKeysWithValues:
                attachments.map { ($0.id, .waiting) }))
            let model = IOSAppModel(library: library, cloudSyncHandler: handler)
            await model.load()
            let pasteboard = RecordingPasteboard()
            let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
            let preparing = Task {
                if use == .copy { return await coordinator.copy(snips: [snip], model: model) }
                await coordinator.share(snips: [snip], model: model)
                return coordinator.shareRequest != nil
            }
            let firstStarted = await TestReadiness.wait(timeout: 2) { await handler.prepareCount() == 1 }
            XCTAssertTrue(firstStarted)
            let deleted = await model.deleteSnip(id: snip.id)
            XCTAssertTrue(deleted)
            let undo = try XCTUnwrap(model.toast)
            await handler.finishPrepare(with: .success(files[0]))
            if use == .copy {
                let secondStarted = await TestReadiness.wait(timeout: 2) { await handler.prepareCount() == 2 }
                XCTAssertTrue(secondStarted)
                XCTAssertTrue(model.attachmentURLs.isEmpty)
                XCTAssertEqual(model.attachmentTransferState(for: attachments[1].id), .waiting)
                await handler.finishPrepare(with: .success(files[1]))
            }
            let published = await preparing.value
            XCTAssertEqual(published, use == .copy)
            XCTAssertTrue(model.snips.isEmpty)
            XCTAssertTrue(model.attachmentURLs.isEmpty)
            XCTAssertEqual(model.toast?.id, undo.id)
            for attachment in attachments {
                XCTAssertNil(model.attachmentURL(for: attachment.id))
                XCTAssertEqual(model.attachmentTransferState(for: attachment.id), .waiting)
            }
            if use == .copy {
                let copied = try XCTUnwrap(pasteboard.writes.first)
                let copiedFiles = copied.compactMap { item -> URL? in
                    if case .file(let url) = item { return url }; return nil
                }
                XCTAssertEqual(try copiedFiles.map { try Data(contentsOf: $0) }, bytes)
            } else {
                XCTAssertTrue(pasteboard.writes.isEmpty)
                XCTAssertNil(coordinator.shareRequest)
            }
        }
    }

    func testReplacementKeepsNewSourcePreparationDuringStatusRefresh() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("New source file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let attachment = try testAttachment(id: UUID(), fileName: "new.txt")
        let current = Snip(content: "New source", origin: .quickEntry, attachments: [attachment])
        let handler = HeldAttachmentStatusHandler(states: [attachment.id: .waiting], urls: [attachment.id: file])
        let model = IOSAppModel(library: ModelTestLibrary(), cloudSyncHandler: handler)
        await model.load()
        await handler.holdNextRead()
        let replacing = Task { await model.replaceLibrary(ModelTestLibrary(snips: [current]), recoveryScope: nil) }
        let held = await TestReadiness.wait(timeout: 2) { await handler.isReadHeld }
        XCTAssertTrue(held)
        XCTAssertEqual(model.snips.first?.id, current.id)
        let prepared = await model.prepareAttachment(attachment.id, for: .copy)
        XCTAssertEqual(prepared, file)
        await handler.releaseRead()
        await replacing.value
        XCTAssertEqual(model.usableAttachmentURL(for: attachment.id), file)
        XCTAssertEqual(model.attachmentTransferState(for: attachment.id), .waiting,
                       "A prepared local file does not mean its upload settled")
    }

    func testMultiAttachmentShareRejectsOrdinaryDeletionWhilePreparing() async throws {
        try await assertMultiAttachmentPreparationRejects(use: .export, mutation: .deleted)
    }

    func testMultiAttachmentCopyRejectsChangedOrRemovedAttachmentWhilePreparing() async throws {
        for mutation in [PreparedSnipMutation.changedAttachment, .removedAttachment, .changedThenDeleted] {
            try await assertMultiAttachmentPreparationRejects(use: .copy, mutation: mutation)
        }
    }

    private enum PreparedSnipMutation {
        case deleted
        case changedAttachment
        case removedAttachment
        case changedThenDeleted
    }

    private func assertMultiAttachmentPreparationRejects(
        use: SyncedAttachmentUse, mutation: PreparedSnipMutation
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFile = root.appendingPathComponent("first.txt")
        let secondFile = root.appendingPathComponent("second.txt")
        try Data("old!".utf8).write(to: firstFile)
        try Data("two!".utf8).write(to: secondFile)
        let attachments = try [testAttachment(id: UUID(), fileName: "first.txt", byteCount: 4),
                               testAttachment(id: UUID(), fileName: "second.txt", byteCount: 4)]
        let snip = Snip(content: "Captured text", origin: .quickEntry, attachments: attachments)
        let library = ModelTestLibrary(snips: [snip])
        let handler = IOSCloudSyncHandlerProbe(states: Dictionary(uniqueKeysWithValues:
            attachments.map { ($0.id, .waiting) }))
        let model = IOSAppModel(library: library, cloudSyncHandler: handler)
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
        let preparing = Task {
            if use == .copy { return await coordinator.copy(snips: [snip], model: model) }
            await coordinator.share(snips: [snip], model: model)
            return coordinator.shareRequest != nil
        }
        let firstStarted = await TestReadiness.wait(timeout: 2) { await handler.prepareCount() == 1 }
        XCTAssertTrue(firstStarted)
        await handler.finishPrepare(with: .success(firstFile))
        let secondStarted = await TestReadiness.wait(timeout: 2) { await handler.prepareCount() == 2 }
        XCTAssertTrue(secondStarted)
        switch mutation {
        case .deleted:
            let deleted = await model.deleteSnip(id: snip.id)
            XCTAssertTrue(deleted)
        case .changedAttachment, .removedAttachment, .changedThenDeleted:
            let retained: [SnipAttachment]
            if mutation == .changedAttachment || mutation == .changedThenDeleted {
                let changed = try testAttachment(id: attachments[0].id, fileName: "changed.txt", byteCount: 4)
                retained = [changed, attachments[1]]
            } else {
                retained = [attachments[1]]
            }
            await library.replaceAttachments(retained, on: snip.id)
            await model.load()
            if mutation == .changedThenDeleted {
                let deleted = await model.deleteSnip(id: snip.id)
                XCTAssertTrue(deleted)
            }
        }
        await handler.finishPrepare(with: .success(secondFile))
        let published = await preparing.value
        XCTAssertFalse(published)
        XCTAssertTrue(pasteboard.writes.isEmpty)
        XCTAssertNil(coordinator.shareRequest)
        if mutation == .deleted || mutation == .changedThenDeleted {
            XCTAssertTrue(model.snips.isEmpty)
            XCTAssertTrue(model.attachmentURLs.isEmpty)
            XCTAssertEqual(model.toast?.action, .undoDelete)
            XCTAssertEqual(model.attachmentTransferState(for: attachments[1].id), .waiting)
        } else {
            XCTAssertEqual(model.snips.first?.isDone, false)
            let saved = await library.snapshot(sortedBy: .manual)
            XCTAssertEqual(saved.snips.first?.isDone, false)
        }
    }

    func testCopyDuringLibraryReplacementCannotCapturePreviousSnapshotBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("previous.txt")
        try Data("Previous source bytes".utf8).write(to: file)
        let attachment = try testAttachment(id: UUID(), fileName: "previous.txt")
        let snip = Snip(content: "Previous snapshot", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCloudSyncHandlerProbe(states: [attachment.id: .waiting])
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]), cloudSyncHandler: handler)
        await model.load()
        // Keep matching IDs and versions so a source check must distinguish the replacement.
        let replacement = ModelTestLibrary(snips: [snip])
        await replacement.suspendNextSnapshot()
        let replacing = Task { await model.replaceLibrary(replacement, recoveryScope: nil) }
        await replacement.waitUntilSnapshotStarts()
        XCTAssertEqual(model.snips.first?.id, snip.id)
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
        var result: Bool?
        let copying = Task { result = await coordinator.copy(snips: [snip], model: model) }
        let finished = await TestReadiness.wait(timeout: 2) { result != nil }
        XCTAssertTrue(finished, "An unavailable source must reject attachment work during replacement")
        XCTAssertEqual(result, false)
        let prepares = await handler.prepareCount()
        XCTAssertEqual(prepares, 0)
        await replacement.resumeSnapshot()
        await replacing.value
        if prepares > 0 { await handler.finishPrepare(with: .success(file)) }
        await copying.value
        XCTAssertTrue(pasteboard.writes.isEmpty)
        XCTAssertEqual(model.snips.first?.isDone, false)
        XCTAssertNil(model.attachmentURL(for: attachment.id))
        let saved = await replacement.snapshot(sortedBy: .manual)
        XCTAssertEqual(saved.snips.first?.isDone, false)
    }

    func testMultiAttachmentCopyRejectsReplacementAndCancellation() async throws {
        for replacesSource in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("prepared.txt")
            try Data("Captured bytes".utf8).write(to: file)
            let attachments = try [testAttachment(id: UUID(), fileName: "first.txt"),
                                   testAttachment(id: UUID(), fileName: "second.txt")]
            let snip = Snip(content: "Retired copy", origin: .quickEntry, attachments: attachments)
            let handler = IOSCloudSyncHandlerProbe(states: Dictionary(uniqueKeysWithValues:
                attachments.map { ($0.id, .waiting) }))
            let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]), cloudSyncHandler: handler)
            await model.load()
            let pasteboard = RecordingPasteboard()
            let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
            let copying = Task { await coordinator.copy(snips: [snip], model: model) }
            let firstStarted = await TestReadiness.wait(timeout: 2) { await handler.prepareCount() == 1 }
            XCTAssertTrue(firstStarted)
            await handler.finishPrepare(with: .success(file))
            let secondStarted = await TestReadiness.wait(timeout: 2) { await handler.prepareCount() == 2 }
            XCTAssertTrue(secondStarted)
            if replacesSource {
                // Even a reset retaining the same snip IDs and versions retires captured bytes.
                await model.replaceLibrary(ModelTestLibrary(snips: [snip]), recoveryScope: nil)
            } else {
                copying.cancel()
            }
            await handler.finishPrepare(with: .success(file))
            let copied = await copying.value
            XCTAssertFalse(copied)
            XCTAssertTrue(pasteboard.writes.isEmpty)
            XCTAssertEqual(model.snips.first?.isDone, false)
            XCTAssertNil(model.toast)
        }
    }

    func testCopyFinishesBeforeAttachmentStatusReadIsReleased() async throws {
        try await assertLocalCopyFinishesBeforeStatus(markingDone: false)
    }

    func testDoneFinishesBeforeAttachmentStatusReadIsReleased() async throws {
        try await assertLocalCopyFinishesBeforeStatus(markingDone: true)
    }

    private func assertLocalCopyFinishesBeforeStatus(markingDone: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = [Data([0, 1, 255]), Data("Second captured file".utf8)]
        let files = [root.appendingPathComponent("first.bin"), root.appendingPathComponent("second.txt")]
        for (file, data) in zip(files, bytes) { try data.write(to: file) }
        let library = try JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
        _ = try await library.perform(.add(content: "Captured text", origin: .quickEntry, source: nil,
            listID: SnipList.inboxID, attachmentURLs: files, requestID: UUID(), now: Date()), sortedBy: .manual)
        let snapshot = try await library.checkedSnapshot(sortedBy: .manual)
        let snip = try XCTUnwrap(snapshot.snips.first)
        let handler = HeldAttachmentStatusHandler()
        let model = IOSAppModel(library: library, cloudSyncHandler: handler)
        await model.load()
        await handler.holdNextRead()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
        var result: Bool?
        let action = Task {
            result = if markingDone { await coordinator.markDone(snips: [snip], model: model) }
                else { await coordinator.copy(snips: [snip], model: model) }
        }
        let held = await TestReadiness.wait(timeout: 2) { await handler.isReadHeld }
        XCTAssertTrue(held, "The action must reach the held attachment-status read")
        let finished = await TestReadiness.wait(timeout: 2) { result != nil }
        XCTAssertTrue(finished, "Local Copy/Done must finish before status is released")
        XCTAssertEqual(result, true)
        XCTAssertEqual(model.snips.first?.isDone, true)
        XCTAssertEqual(model.toast?.action, .undoDone)
        let saved = try await JSONSnipLibrary(fileURL: root.appendingPathComponent("snips.json"))
            .checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(saved.snips.first?.isDone, true)
        let copied = try XCTUnwrap(pasteboard.writes.first)
        XCTAssertEqual(copied.first, .text("Captured text"))
        let copiedFiles = copied.compactMap { item -> URL? in
            if case .file(let url) = item { return url }; return nil
        }
        XCTAssertEqual(try copiedFiles.map { try Data(contentsOf: $0) }, bytes)
        await handler.releaseRead()
        await action.value
        let undo = try XCTUnwrap(model.toast)
        await model.performToastActionNow(undo)
        XCTAssertEqual(model.snips.first?.isDone, false)
        let restored = try await library.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(restored.snips.first?.isDone, false)
        let explicitSyncs = await handler.explicitSyncs
        XCTAssertEqual(explicitSyncs, 0)
    }

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

    func testCopyShareCoordinatorWritesWholePlansAndStopsForUnavailableFiles() async throws {
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
        let model = IOSAppModel(
            library: ModelTestLibrary(
                snips: [mixed, missing],
                attachmentURLs: [availableID: fileURL]
            ),
            initialSnapshot: snapshot
        )
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        await coordinator.copy(snips: [mixed], model: model)
        XCTAssertEqual(pasteboard.writes, [[.text("Text"), .file(fileURL)]])
        await coordinator.copyText(snips: [mixed], model: model)
        XCTAssertEqual(pasteboard.writes.last, [.text("Text")])
        await coordinator.copyAttachments(snips: [mixed], model: model)
        XCTAssertEqual(pasteboard.writes.last, [.file(fileURL)])
        await coordinator.share(snips: [mixed], model: model)
        XCTAssertEqual(coordinator.shareRequest?.items, [.text("Text"), .file(fileURL)])

        let writeCount = pasteboard.writes.count
        await coordinator.copy(snips: [missing], model: model)
        XCTAssertEqual(pasteboard.writes.count, writeCount)
        XCTAssertEqual(coordinator.unavailableFilesNotice?.payload.unavailableFileNames, ["missing.txt"])
        await coordinator.copyTextFromNotice(try XCTUnwrap(coordinator.unavailableFilesNotice), model: model)
        XCTAssertEqual(pasteboard.writes.last, [.text("Safe text")])
        XCTAssertNil(coordinator.unavailableFilesNotice)
    }

    func testCopyTextOnlyRetainsSelectedNoticeAfterAlertDismissal() async throws {
        let attachment = try testAttachment(id: UUID(), fileName: "missing.txt")
        let snip = Snip(content: "Safe text", origin: .quickEntry, attachments: [attachment])
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
        let initialCopy = await coordinator.copy(snips: [snip], model: model)
        XCTAssertFalse(initialCopy)
        let selectedNotice = try XCTUnwrap(coordinator.unavailableFilesNotice)

        // SwiftUI clears the presentation binding before the button's Task runs.
        coordinator.cancelUnavailableFilesNotice()
        XCTAssertTrue(pasteboard.writes.isEmpty)
        XCTAssertFalse(try XCTUnwrap(model.snips.first).isDone)
        let copied = await coordinator.copyTextFromNotice(selectedNotice, model: model)

        XCTAssertTrue(copied)
        XCTAssertEqual(pasteboard.writes, [[.text("Safe text")]])
        XCTAssertTrue(try XCTUnwrap(model.snips.first).isDone)
        XCTAssertEqual(model.toast?.message, "Snapped")
    }

    func testCopyChecksSnipAndCheckingCopiesSnip() async throws {
        let first = Snip(content: "Copy checks", origin: .quickEntry)
        let second = Snip(content: "Check copies", origin: .quickEntry)
        let feedback = makeFeedback()
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [first, second]),
            haptics: feedback
        )
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        let copied = await coordinator.copy(snips: [first], model: model)
        XCTAssertTrue(copied)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == first.id }).isDone)
        XCTAssertEqual(feedback.event?.kinds, [.copied, .markedDone])

        let checked = await coordinator.toggleDone(snip: second, model: model)
        XCTAssertTrue(checked)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == second.id }).isDone)
        XCTAssertEqual(pasteboard.writes.last, [.text("Check copies")])
        XCTAssertEqual(feedback.event?.kinds, [.copied, .markedDone])
    }

    func testMarkDoneCopiesOnlyCurrentUnfinishedUnpinnedSnips() async throws {
        let unfinished = Snip(content: "Unfinished", origin: .quickEntry)
        let done = Snip(content: "Done", origin: .quickEntry, isDone: true)
        let pinned = Snip(content: "Pinned", origin: .quickEntry, pinnedAt: Date())
        let model = IOSAppModel(library: ModelTestLibrary(snips: [unfinished, done, pinned]))
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        let marked = await coordinator.markDone(
            snips: [unfinished, done, pinned],
            model: model
        )

        XCTAssertTrue(marked)
        XCTAssertEqual(pasteboard.writes, [[.text("Unfinished")]])
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == unfinished.id }).isDone)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == done.id }).isDone)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == pinned.id }).isPinned)
    }

    func testToggleDoneUsesCurrentStateInsteadOfViewSnapshot() async throws {
        let original = Snip(content: "Current state", origin: .quickEntry)
        let model = IOSAppModel(library: ModelTestLibrary(snips: [original]))
        await model.load()
        let initiallyToggled = await model.toggleDone(id: original.id)
        XCTAssertTrue(initiallyToggled)
        let staleDone = try XCTUnwrap(model.snips.first { $0.id == original.id })
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        let reopened = await coordinator.toggleDone(snip: original, model: model)
        XCTAssertTrue(reopened)
        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == original.id }).isDone)
        XCTAssertTrue(pasteboard.writes.isEmpty)

        let checked = await coordinator.toggleDone(snip: staleDone, model: model)
        XCTAssertTrue(checked)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == original.id }).isDone)
        XCTAssertEqual(pasteboard.writes, [[.text("Current state")]])
    }

    func testCopyFeedbackKeepsItsFullLifetimeAfterWritingPasteboard() async throws {
        let snip = Snip(content: "Copy feedback", origin: .quickEntry, pinnedAt: Date())
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]))
        await model.load()
        let pasteboard = RecordingPasteboard()
        var writeFinishedAt: ContinuousClock.Instant?
        pasteboard.onNextWrite = { writeFinishedAt = ContinuousClock().now }
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        let copied = await coordinator.copyText(snips: [snip], model: model)

        XCTAssertTrue(copied)
        XCTAssertEqual(pasteboard.writes, [[.text("Copy feedback")]])
        let finishedAt = try XCTUnwrap(writeFinishedAt)
        let toast = try XCTUnwrap(model.toast)
        XCTAssertEqual(toast.message, "Snapped")
        XCTAssertEqual(toast.detail, "Text copied")
        XCTAssertNil(toast.action)
        XCTAssertEqual(toast.duration, .seconds(3))
        XCTAssertGreaterThanOrEqual(
            toast.expiresAt, finishedAt.advanced(by: toast.duration),
            "Pasteboard work must not consume the copy feedback's visible lifetime."
        )
    }

    func testCopyUsesCurrentContentInsteadOfViewSnapshot() async throws {
        let original = Snip(content: "Old content", origin: .quickEntry)
        let model = IOSAppModel(library: ModelTestLibrary(snips: [original]))
        await model.load()
        let edited = await model.editSnip(original, content: "Current content")
        XCTAssertTrue(edited)
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        let copied = await coordinator.copyText(snips: [original], model: model)

        XCTAssertTrue(copied)
        XCTAssertEqual(pasteboard.writes, [[.text("Current content")]])
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == original.id }).isDone)
    }

    func testNewerCopyWinsWhileOlderAttachmentPreparationWaits() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let attachment = try testAttachment(id: UUID(), fileName: "note.txt")
        let older = Snip(content: "Older copy", origin: .quickEntry, attachments: [attachment])
        let newer = Snip(content: "Newer copy", origin: .quickEntry)
        let handler = IOSCloudSyncHandlerProbe(states: [attachment.id: .waiting])
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [older, newer]),
            cloudSyncHandler: handler
        )
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
        let olderCopy = Task { await coordinator.copy(snips: [older], model: model) }
        await handler.waitUntilPrepareStarts()

        let newerCopied = await coordinator.copy(snips: [newer], model: model)
        await handler.finishPrepare(with: .success(file))
        let olderCopied = await olderCopy.value

        XCTAssertTrue(newerCopied)
        XCTAssertFalse(olderCopied)
        XCTAssertEqual(pasteboard.writes, [[.text("Newer copy")]])
        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == older.id }).isDone)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == newer.id }).isDone)
        XCTAssertNil(coordinator.unavailableFilesNotice)
    }

    func testNewerShareWinsWhileOlderAttachmentPreparationWaits() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let attachment = try testAttachment(id: UUID(), fileName: "note.txt")
        let older = Snip(content: "Older share", origin: .quickEntry, attachments: [attachment])
        let newer = Snip(content: "Newer share", origin: .quickEntry)
        let handler = IOSCloudSyncHandlerProbe(states: [attachment.id: .waiting])
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [older, newer]),
            cloudSyncHandler: handler
        )
        await model.load()
        let coordinator = IOSCopyShareCoordinator(pasteboard: RecordingPasteboard())
        let olderShare = Task { await coordinator.share(snips: [older], model: model) }
        await handler.waitUntilPrepareStarts()

        await coordinator.share(snips: [newer], model: model)
        let newerItems = coordinator.shareRequest?.items
        await handler.finishPrepare(with: .success(file))
        await olderShare.value

        XCTAssertEqual(newerItems, [.text("Newer share")])
        XCTAssertEqual(coordinator.shareRequest?.items, [.text("Newer share")])
        XCTAssertNil(coordinator.unavailableFilesNotice)
    }

    func testOlderShareDoesNotClearNewerShareUnavailableFilesNotice() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let olderAttachment = try testAttachment(id: UUID(), fileName: "older.txt")
        let newerAttachment = try testAttachment(id: UUID(), fileName: "newer.txt")
        let older = Snip(content: "Older share", origin: .quickEntry, attachments: [olderAttachment])
        let newer = Snip(content: "Newer share", origin: .quickEntry, attachments: [newerAttachment])
        let handler = IOSCloudSyncHandlerProbe(states: [
            olderAttachment.id: .waiting,
            newerAttachment.id: .waiting,
        ])
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [older, newer]),
            cloudSyncHandler: handler
        )
        await model.load()
        let diagnostics = IOSDiagnosticRecorderProbe()
        let coordinator = IOSCopyShareCoordinator(
            pasteboard: RecordingPasteboard(),
            diagnostics: diagnostics.recorder
        )
        let olderShare = Task { await coordinator.share(snips: [older], model: model) }
        await handler.waitUntilPrepareStarts()

        let newerShare = Task { await coordinator.share(snips: [newer], model: model) }
        await handler.waitUntilPrepareCount(2)
        await handler.finishPrepare(with: .failure(SnipLibraryError.attachmentCopyFailed), at: 1)
        await newerShare.value
        let newerFileNames = coordinator.unavailableFilesNotice?.payload.unavailableFileNames
        let newerShareRequest = coordinator.shareRequest
        let newerDiagnostics = diagnostics.events.map(\.line)
        await handler.finishPrepare(with: .success(file))
        await olderShare.value

        XCTAssertEqual(newerFileNames, ["newer.txt"])
        XCTAssertNil(newerShareRequest)
        XCTAssertEqual(diagnostics.events.filter { $0.operation == "attachment.prepare" }.count, 1)
        XCTAssertEqual(coordinator.unavailableFilesNotice?.payload.unavailableFileNames, ["newer.txt"])
        XCTAssertNil(coordinator.shareRequest)
        XCTAssertEqual(diagnostics.events.map(\.line), newerDiagnostics)
    }

    func testNewerCopyPreventsOlderPostWriteCompletionWhileLibraryIsLocked() async throws {
        let older = Snip(content: "Older copy", origin: .quickEntry)
        let newer = Snip(content: "Newer copy", origin: .quickEntry, pinnedAt: Date())
        let blocker = Snip(content: "Hold the lock", origin: .quickEntry)
        let library = ModelTestLibrary(
            snips: [older, newer, blocker],
            suspendsFirstCommand: true
        )
        let model = IOSAppModel(library: library)
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
        let blockerTask = Task {
            await model.editSnip(blocker, content: "Lock held")
        }
        await library.waitUntilFirstCommandStarts()
        let olderWrite = expectation(description: "Older copy writes to the pasteboard")
        pasteboard.onNextWrite = {
            olderWrite.fulfill()
        }
        let olderCopy = Task {
            await coordinator.copyText(snips: [older], model: model)
        }
        await fulfillment(of: [olderWrite], timeout: TestReadiness.timeout)
        XCTAssertEqual(pasteboard.writes, [[.text("Older copy")]])

        let newerCopied = await coordinator.copyText(snips: [newer], model: model)
        await library.resumeFirstCommand()
        let blockerSaved = await blockerTask.value
        let olderCopied = await olderCopy.value

        XCTAssertTrue(newerCopied)
        XCTAssertTrue(blockerSaved)
        XCTAssertTrue(olderCopied)
        XCTAssertEqual(pasteboard.writes, [[.text("Older copy")], [.text("Newer copy")]])
        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == older.id }).isDone)
    }

    func testAdmittedDoneKeepsNewerCopyFailureVisibleAndUndoable() async throws {
        let older = Snip(content: "Older successful copy", origin: .quickEntry)
        let newer = Snip(content: "Newer failed copy", origin: .quickEntry)
        let library = ModelTestLibrary(
            snips: [older, newer],
            suspendsFirstCommand: true
        )
        let model = IOSAppModel(library: library)
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
        let olderCopy = Task {
            await coordinator.copyText(snips: [older], model: model)
        }
        await library.waitUntilFirstCommandStarts()

        pasteboard.succeeds = false
        let newerCopied = await coordinator.copyText(snips: [newer], model: model)
        let newerFailure = model.failure
        let newerWarningAction = model.toast?.action
        await library.resumeFirstCommand()
        let olderCopied = await olderCopy.value

        XCTAssertTrue(olderCopied)
        XCTAssertFalse(newerCopied)
        let failure = try XCTUnwrap(newerFailure)
        XCTAssertEqual(failure.operation, "clipboard.write")
        XCTAssertEqual(newerWarningAction, .showErrorDetails(failure.id))
        XCTAssertEqual(model.failure?.id, failure.id)
        XCTAssertEqual(model.inlineFailure?.id, failure.id)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == older.id }).isDone)
        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == newer.id }).isDone)
        let undo = try XCTUnwrap(model.toast)
        XCTAssertEqual(undo.action, .undoDone)
        XCTAssertEqual(pasteboard.writes, [
            [.text("Older successful copy")], [.text("Newer failed copy")]
        ])

        await model.performToastActionNow(undo)

        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == older.id }).isDone)
        XCTAssertEqual(model.inlineFailure?.id, failure.id)
        XCTAssertEqual(pasteboard.writes, [
            [.text("Older successful copy")], [.text("Newer failed copy")]
        ])
    }

    func testClipboardHistoryCopyWinsWhileOlderSnipCopyWaits() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let attachment = try testAttachment(id: UUID(), fileName: "note.txt")
        let snip = Snip(content: "Older snip copy", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCloudSyncHandlerProbe(states: [attachment.id: .waiting])
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip]),
            cloudSyncHandler: handler
        )
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
        let olderCopy = Task { await coordinator.copy(snips: [snip], model: model) }
        await handler.waitUntilPrepareStarts()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapClipboardRace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let clipboard = IOSClipboardModel(
            rootURL: root,
            settings: SyncedContentSettingsModel(mode: .localOnly),
            preferences: preferences
        )
        let entry = ClipboardEntry(items: [ClipboardPayloadItem(representations: [
            ClipboardRepresentation(type: UTType.utf8PlainText.identifier, data: Data("Newer history copy".utf8)),
        ])])
        _ = await coordinator.copyClipboardEntry(entry, clipboard: clipboard).value
        await handler.finishPrepare(with: .success(file))
        let copied = await olderCopy.value

        XCTAssertFalse(copied)
        XCTAssertTrue(pasteboard.writes.isEmpty)
        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == snip.id }).isDone)
    }

    func testCopyTextFromNoticeDoesNotFinishANewerEdit() async throws {
        let attachment = try testAttachment(id: UUID(), fileName: "missing.txt")
        let original = Snip(content: "Original text", origin: .quickEntry, attachments: [attachment])
        let model = IOSAppModel(library: ModelTestLibrary(snips: [original]))
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)
        let initialCopy = await coordinator.copy(snips: [original], model: model)
        XCTAssertFalse(initialCopy)

        let edited = await model.editSnip(original, content: "Edited text")
        XCTAssertTrue(edited)
        let copiedText = await coordinator.copyTextFromNotice(try XCTUnwrap(coordinator.unavailableFilesNotice), model: model)

        XCTAssertTrue(copiedText)
        XCTAssertEqual(pasteboard.writes, [[.text("Original text")]])
        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == original.id }).isDone)
    }

    func testCopyDoesNotUndoANewerReopenWhileAttachmentPreparationWaits() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let attachment = try testAttachment(id: UUID(), fileName: "note.txt")
        let snip = Snip(content: "Copy me", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCloudSyncHandlerProbe(states: [attachment.id: .waiting])
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip]),
            cloudSyncHandler: handler
        )
        await model.load()
        let coordinator = IOSCopyShareCoordinator(pasteboard: RecordingPasteboard())
        let copy = Task { await coordinator.copy(snips: [snip], model: model) }
        await handler.waitUntilPrepareStarts()

        let checked = await model.toggleDone(id: snip.id)
        let reopened = await model.toggleDone(id: snip.id)
        await handler.finishPrepare(with: .success(file))
        let copied = await copy.value

        XCTAssertTrue(checked)
        XCTAssertTrue(reopened)
        XCTAssertTrue(copied)
        XCTAssertFalse(try XCTUnwrap(model.snips.first { $0.id == snip.id }).isDone)
    }

    func testCopyAndCopyAttachmentsPrepareEachUniqueAttachmentWithCopyIntent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCopyPrepare-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preparedURL = directory.appendingPathComponent("prepared.txt")
        let preparedAttachmentsURL = directory.appendingPathComponent("prepared-again.txt")
        try Data("Prepared".utf8).write(to: preparedURL)
        try Data("Prepared again".utf8).write(to: preparedAttachmentsURL)
        let attachmentID = UUID()
        let attachment = try testAttachment(id: attachmentID, fileName: "prepared.txt")
        let first = Snip(content: "First", origin: .quickEntry, attachments: [attachment])
        let second = Snip(content: "Second", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCopyShareActionHandlerProbe(
            states: [attachmentID: .waiting],
            results: [.success(preparedURL), .success(preparedAttachmentsURL)]
        )
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [first, second]),
            cloudSyncHandler: handler
        )
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        await coordinator.copy(snips: [second, first], model: model)

        let calls = await handler.prepareCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, attachmentID)
        XCTAssertEqual(calls.first?.use, .copy)
        XCTAssertEqual(
            pasteboard.writes,
            [[.text(SnipFormatter.formatForClipboard(snips: [second, first])), .file(preparedURL)]]
        )

        try FileManager.default.removeItem(at: preparedURL)
        await coordinator.copyAttachments(snips: [first, second], model: model)

        let allCalls = await handler.prepareCalls()
        XCTAssertEqual(allCalls.count, 2)
        XCTAssertEqual(allCalls.last?.id, attachmentID)
        XCTAssertEqual(allCalls.last?.use, .copy)
        XCTAssertEqual(pasteboard.writes.last, [.file(preparedAttachmentsURL)])
    }

    func testShareUsesExportAndDoesNotCreateAPartialRequestAfterPrepareFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapSharePrepare-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let secondURL = directory.appendingPathComponent("second.txt")
        try Data("Second".utf8).write(to: secondURL)
        let firstID = UUID()
        let secondID = UUID()
        let firstAttachment = try testAttachment(id: firstID, fileName: "first.txt")
        let secondAttachment = try testAttachment(id: secondID, fileName: "second.txt")
        let snip = Snip(
            content: "Share",
            origin: .quickEntry,
            attachments: [firstAttachment, secondAttachment]
        )
        let handler = IOSCopyShareActionHandlerProbe(
            states: [firstID: .waiting, secondID: .waiting],
            results: [.failure(SnipLibraryError.attachmentCopyFailed), .success(secondURL)]
        )
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]), cloudSyncHandler: handler)
        await model.load()
        let coordinator = IOSCopyShareCoordinator(pasteboard: RecordingPasteboard())

        await coordinator.share(snips: [snip], model: model)

        let calls = await handler.prepareCalls()
        XCTAssertEqual(calls.map(\.id), [firstID, secondID])
        XCTAssertEqual(calls.map(\.use), [.export, .export])
        XCTAssertNil(coordinator.shareRequest)
        XCTAssertEqual(coordinator.unavailableFilesNotice?.payload.unavailableFileNames, ["first.txt"])
        XCTAssertNil(model.errorMessage)
    }

    func testCopyFailureWritesNothingAndCanRetryWithoutACompetingAlert() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCopyRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preparedURL = directory.appendingPathComponent("retry.txt")
        try Data("Retry".utf8).write(to: preparedURL)
        let attachmentID = UUID()
        let attachment = try testAttachment(id: attachmentID, fileName: "retry.txt")
        let snip = Snip(content: "Retry", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCopyShareActionHandlerProbe(
            states: [attachmentID: .waiting],
            results: [.failure(SnipLibraryError.attachmentCopyFailed), .success(preparedURL)]
        )
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]), cloudSyncHandler: handler)
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        await coordinator.copy(snips: [snip], model: model)

        XCTAssertTrue(pasteboard.writes.isEmpty)
        XCTAssertEqual(coordinator.unavailableFilesNotice?.payload.unavailableFileNames, ["retry.txt"])
        XCTAssertNil(model.errorMessage)

        await coordinator.copy(snips: [snip], model: model)

        XCTAssertEqual(pasteboard.writes, [[.text("Retry"), .file(preparedURL)]])
        XCTAssertNil(coordinator.unavailableFilesNotice)
        let calls = await handler.prepareCalls()
        XCTAssertEqual(calls.map(\.use), [.copy, .copy])
    }

    func testCopyNoticeRecordsOnePreflightFailureForTheVisibleNotice() async throws {
        let attachment = try testAttachment(id: UUID(), fileName: "private.txt")
        let snip = Snip(content: "Copy", origin: .quickEntry, attachments: [attachment])
        let diagnostics = IOSDiagnosticRecorderProbe()
        let handler = IOSCopyShareActionHandlerProbe(
            states: [attachment.id: .waiting],
            results: Array(repeating: .failure(IOSCachePreflightFailure.pathOutsideRoot), count: 2)
        )
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip]),
            cloudSyncHandler: handler,
            diagnostics: diagnostics.recorder
        )
        await model.load()
        let coordinator = IOSCopyShareCoordinator(
            pasteboard: RecordingPasteboard(),
            diagnostics: diagnostics.recorder
        )

        _ = await coordinator.copy(snips: [snip], model: model)
        _ = await coordinator.copy(snips: [snip], model: model)

        XCTAssertNotNil(coordinator.unavailableFilesNotice)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, "attachment.prepare")
        XCTAssertEqual(diagnostics.events.first?.errorCode, "storage.pathOutsideRoot")
        XCTAssertFalse(diagnostics.events.first?.line.contains("private.txt") ?? true)
    }

    func testUnavailableLocalPayloadRecordsOneAttachmentFailureAtNotice() async throws {
        let attachment = try testAttachment(id: UUID(), fileName: "missing.txt")
        let snip = Snip(content: "Copy", origin: .quickEntry, attachments: [attachment])
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip], attachmentURLs: [attachment.id: missingURL]),
            diagnostics: diagnostics.recorder
        )
        await model.load()
        let coordinator = IOSCopyShareCoordinator(
            pasteboard: RecordingPasteboard(),
            diagnostics: diagnostics.recorder
        )

        _ = await coordinator.copy(snips: [snip], model: model)

        XCTAssertNotNil(coordinator.unavailableFilesNotice)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, "attachment.prepare")
        XCTAssertEqual(diagnostics.events.first?.errorCode, "attachment.unavailableAfterPrepare")
    }

    func testDifferentUnavailableFilesReplaceNoticeWithAnotherEvent() async throws {
        let first = try testAttachment(id: UUID(), fileName: "private-first.txt")
        let second = try testAttachment(id: UUID(), fileName: "private-second.txt")
        let firstSnip = Snip(content: "First", origin: .quickEntry, attachments: [first])
        let secondSnip = Snip(content: "Second", origin: .quickEntry, attachments: [second])
        let missingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(
            library: ModelTestLibrary(
                snips: [firstSnip, secondSnip],
                attachmentURLs: [
                    first.id: missingRoot.appendingPathComponent("first"),
                    second.id: missingRoot.appendingPathComponent("second"),
                ]
            ),
            diagnostics: diagnostics.recorder
        )
        await model.load()
        let coordinator = IOSCopyShareCoordinator(
            pasteboard: RecordingPasteboard(),
            diagnostics: diagnostics.recorder
        )

        _ = await coordinator.copy(snips: [firstSnip], model: model)
        _ = await coordinator.copy(snips: [secondSnip], model: model)

        XCTAssertEqual(coordinator.unavailableFilesNotice?.payload.unavailableFileNames, ["private-second.txt"])
        XCTAssertEqual(diagnostics.events.count, 2)
        XCTAssertTrue(diagnostics.events.allSatisfy { $0.operation == "attachment.prepare" })
        XCTAssertFalse(diagnostics.events.map(\.line).joined().contains("private-"))
    }

    func testCancelledCopyAndShareDoNotPresentUnavailableFileNotice() async throws {
        let attachment = try testAttachment(id: UUID(), fileName: "private.txt")
        let snip = Snip(content: "Copy", origin: .quickEntry, attachments: [attachment])
        let diagnostics = IOSDiagnosticRecorderProbe()
        let handler = IOSCopyShareActionHandlerProbe(
            states: [attachment.id: .waiting],
            results: Array(repeating: .failure(CancellationError()), count: 2)
        )
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip]),
            cloudSyncHandler: handler,
            diagnostics: diagnostics.recorder
        )
        await model.load()
        let coordinator = IOSCopyShareCoordinator(
            pasteboard: RecordingPasteboard(),
            diagnostics: diagnostics.recorder
        )

        let copied = await coordinator.copy(snips: [snip], model: model)
        XCTAssertFalse(copied)
        await coordinator.share(snips: [snip], model: model)

        XCTAssertNil(coordinator.unavailableFilesNotice)
        XCTAssertNil(coordinator.shareRequest)
        XCTAssertTrue(diagnostics.events.isEmpty)
    }

    func testCopyAttachmentsFailureShowsTheTextFallbackNotice() async throws {
        let attachment = try testAttachment(id: UUID(), fileName: "missing.txt")
        let snip = Snip(content: "Text remains", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCopyShareActionHandlerProbe(
            states: [attachment.id: .waiting],
            results: [.failure(SnipLibraryError.attachmentCopyFailed)]
        )
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip]),
            cloudSyncHandler: handler
        )
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        let copied = await coordinator.copyAttachments(snips: [snip], model: model)

        XCTAssertFalse(copied)
        XCTAssertTrue(pasteboard.writes.isEmpty)
        XCTAssertEqual(
            coordinator.unavailableFilesNotice?.payload.unavailableFileNames,
            ["missing.txt"]
        )
        XCTAssertFalse(try XCTUnwrap(model.snips.first).isDone)
    }

    func testCopyTextNeverPreparesAttachments() async throws {
        let attachmentID = UUID()
        let attachment = try testAttachment(id: attachmentID, fileName: "remote.txt")
        let snip = Snip(content: "Text only", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCopyShareActionHandlerProbe(
            states: [attachmentID: .waiting],
            results: []
        )
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]), cloudSyncHandler: handler)
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        await coordinator.copyText(snips: [snip], model: model)

        XCTAssertEqual(pasteboard.writes, [[.text("Text only")]])
        let calls = await handler.prepareCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testCopyUsesCachedLocalFileWithoutCallingCloudHandler() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCopyCached-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cachedURL = directory.appendingPathComponent("cached.txt")
        try Data("Cached".utf8).write(to: cachedURL)
        let attachmentID = UUID()
        let attachment = try testAttachment(id: attachmentID, fileName: "cached.txt")
        let snip = Snip(content: "Cached", origin: .quickEntry, attachments: [attachment])
        let handler = IOSCopyShareActionHandlerProbe(states: [:], results: [])
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip], attachmentURLs: [attachmentID: cachedURL]),
            cloudSyncHandler: handler
        )
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        await coordinator.copy(snips: [snip], model: model)

        XCTAssertEqual(pasteboard.writes, [[.text("Cached"), .file(cachedURL)]])
        let calls = await handler.prepareCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testRepeatedCopyUsesTheVerifiedSyncedFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCopyVerifiedCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cachedURL = directory.appendingPathComponent("cached.txt")
        try Data("Cached".utf8).write(to: cachedURL)
        let attachmentID = UUID()
        let attachment = try testAttachment(id: attachmentID, fileName: "cached.txt")
        let snip = Snip(
            content: "Cached",
            origin: .quickEntry,
            pinnedAt: Date(),
            attachments: [attachment]
        )
        let handler = IOSCopyShareActionHandlerProbe(
            states: [attachmentID: .available],
            results: [.success(cachedURL)]
        )
        let model = IOSAppModel(library: ModelTestLibrary(snips: [snip]), cloudSyncHandler: handler)
        await model.load()
        let pasteboard = RecordingPasteboard()
        let coordinator = IOSCopyShareCoordinator(pasteboard: pasteboard)

        await coordinator.copy(snips: [snip], model: model)
        await coordinator.copy(snips: [snip], model: model)

        XCTAssertEqual(pasteboard.writes.count, 2)
        let calls = await handler.prepareCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls.allSatisfy { $0.id == attachmentID && $0.use == .copy })
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
        XCTAssertEqual(leaseDirectories(in: stagingRoot).count, 1)
        pasteboard.string = "External replacement"
        let released = await TestReadiness.wait { leaseDirectories(in: stagingRoot).isEmpty }
        XCTAssertTrue(released, "Replacing the pasteboard must remove the staged files")
    }

    func testPasteboardLeaseSurvivesRelaunchOnlyWhileItsChangeCountMatches() throws {
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
        let leaseDirectory = try XCTUnwrap(leaseDirectories(in: stagingRoot).first)
        firstWriter = nil

        _ = IOSSystemPasteboard(
            pasteboard: pasteboard,
            stagingRoot: stagingRoot
        )
        XCTAssertEqual(leaseDirectories(in: stagingRoot), [leaseDirectory])

        pasteboard.string = "Changed while Snip Snap was not running"
        _ = IOSSystemPasteboard(
            pasteboard: pasteboard,
            stagingRoot: stagingRoot
        )
        XCTAssertEqual(leaseDirectories(in: stagingRoot), [])
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
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let writer = IOSSystemPasteboard(pasteboard: pasteboard, stagingRoot: stagingRoot)
        XCTAssertTrue(writer.write([.file(sourceURL)]))
        XCTAssertEqual(leaseDirectories(in: stagingRoot).count, 1)

        UIPasteboard.remove(withName: pasteboardName)

        let released = await TestReadiness.wait { leaseDirectories(in: stagingRoot).isEmpty }
        XCTAssertTrue(released, "Removing the pasteboard must remove the staged files")
    }

    func testTextOnlyWriteReleasesEarlierFileLeaseWithoutPasteboardNotifications() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapPasteboardSilent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.txt")
        try Data("Lease".utf8).write(to: sourceURL)
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let writer = IOSSystemPasteboard(pasteboard: SilentItemProviderPasteboard(), stagingRoot: stagingRoot)
        XCTAssertTrue(writer.write([.file(sourceURL)]))
        XCTAssertEqual(leaseDirectories(in: stagingRoot).count, 1)

        XCTAssertTrue(writer.write([.text("Text only")]))

        XCTAssertEqual(leaseDirectories(in: stagingRoot), [])
    }

    func testFailedFileWriteKeepsEarlierFileLease() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapPasteboardFailedWrite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.txt")
        try Data("Lease".utf8).write(to: sourceURL)
        let pasteboardName = UIPasteboard.Name("SnipSnapTests.\(UUID().uuidString)")
        let pasteboard = try XCTUnwrap(UIPasteboard(name: pasteboardName, create: true))
        defer { UIPasteboard.remove(withName: pasteboardName) }
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let writer = IOSSystemPasteboard(pasteboard: pasteboard, stagingRoot: stagingRoot)
        XCTAssertTrue(writer.write([.file(sourceURL)]))
        let leaseDirectory = try XCTUnwrap(leaseDirectories(in: stagingRoot).first)

        XCTAssertFalse(writer.write([.file(directory.appendingPathComponent("missing.txt"))]))

        XCTAssertEqual(leaseDirectories(in: stagingRoot), [leaseDirectory])
    }
}

/// The pasteboard's staged lease directories, as the next launch would find them.
private func leaseDirectories(in stagingRoot: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)) ?? []
}

/// Never posts pasteboard notifications, so only `write` can release a lease.
@MainActor
private final class SilentItemProviderPasteboard: IOSItemProviderPasteboard {
    let name = UIPasteboard.Name("SnipSnapTests.\(UUID().uuidString)")
    private(set) var changeCount = 0

    func setItemProviders(_ itemProviders: [NSItemProvider], localOnly: Bool, expirationDate: Date?) {
        changeCount += 1
    }
}
