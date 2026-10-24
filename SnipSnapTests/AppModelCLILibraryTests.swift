import AppKit
import Foundation
import SnipSnapCore
import SnipSnapPersistence
import XCTest
@testable import SnipSnap

final class AppModelCLILibraryTests: StoreBackedTestCase {
    @MainActor
    func testOpenListDialogRejectsCLIListEditWithoutChangingList() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let model = AppModel(library: library, defaults: defaults())
        let created = try await model.handleCLIRequest(.init(action: .createList(name: "Original")))
        let list = try XCTUnwrap(created.lists.first)
        let read = try await model.handleCLIRequest(.init(action: .showList(selector: list.id.uuidString)))
        let revision = try XCTUnwrap(read.listRevision)
        model.cliDialogIsPresented = { true }
        do {
            _ = try await model.handleCLIRequest(.init(action: .extended(.library(.editList(
                id: list.id, revision: revision, name: "CLI name", icon: nil, color: nil
            )))))
            XCTFail("An open list form must retain ownership of its unsaved values")
        } catch SnipCLIRequestError.editingInProgress {}
        let after = try await library.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(after.lists.first { $0.id == list.id }?.name, "Original")
        XCTAssertFalse(model.isCLIInteractionReserved)
    }

    @MainActor
    func testBulkDeleteReturnsUndoTokenAndRestoreKeepsDraft() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let first = try await add("First", to: library)
        let second = try await add("Second", to: library)
        let model = AppModel(library: library, defaults: defaults())
        model.saveComposerText("Keep this draft", for: SnipList.inboxID)
        let action = SnipCLILibraryAction.delete(snips: [reference(first), reference(second)])
        let receipt = try await model.handleCLIRequest(.init(action: .extended(.library(action))))
        guard case .library(let result) = receipt.extendedResult else { return XCTFail("Expected delete token.") }
        let token = try XCTUnwrap(result.undoToken)
        XCTAssertTrue(model.snips.isEmpty)
        _ = try await model.handleCLIRequest(.init(action: .extended(.library(.undo(token: token)))))
        XCTAssertEqual(Set(model.snips.map(\.id)), [first.id, second.id])
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "Keep this draft")
    }

    @MainActor
    func testActiveEditRejectsBulkWriteWithoutClearingEditOrDraft() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let snip = try await add("Editing", to: library)
        let model = AppModel(library: library, defaults: defaults())
        model.editingID = snip.id
        model.saveComposerText("Draft", for: SnipList.inboxID)
        let action = SnipCLILibraryAction.setDone(snips: [reference(snip)], done: true)
        do {
            _ = try await model.handleCLIRequest(.init(action: .extended(.library(action))))
            XCTFail("An active edit must block the write.")
        } catch SnipCLIRequestError.editingInProgress {}
        XCTAssertEqual(model.editingID, snip.id)
        XCTAssertEqual(model.composerDraft(for: SnipList.inboxID).text, "Draft")
        let snapshot = try await library.checkedSnapshot(sortedBy: .manual)
        XCTAssertFalse(try XCTUnwrap(snapshot.snips.first).isDone)
    }

    @MainActor
    func testCopyMarksOrdinarySnipDoneAndPreservesPinnedSnip() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let ordinary = try await add("Ordinary", to: library)
        let reusable = try await add("Reusable", to: library)
        let pinned = try await library.perform(.setPinned(ids: [reusable.id], pinned: true), sortedBy: .manual)
        let currentPin = try XCTUnwrap(pinned.snapshot.snips.first { $0.id == reusable.id })
        let model = AppModel(library: library, defaults: defaults())
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let action = SnipCLILibraryAction.copy(snips: [reference(ordinary), reference(currentPin)], markDone: true)
        _ = try await model.handleCLILibraryRequest(.init(action: .extended(.library(action))), action: action, to: pasteboard)
        XCTAssertTrue(try XCTUnwrap(pasteboard.string(forType: .string)).contains("Ordinary"))
        let snapshot = try await library.checkedSnapshot(sortedBy: .manual)
        XCTAssertTrue(try XCTUnwrap(snapshot.snips.first { $0.id == ordinary.id }).isDone)
        let copiedPin = try XCTUnwrap(snapshot.snips.first { $0.id == reusable.id })
        XCTAssertFalse(copiedPin.isDone)
        XCTAssertEqual(copiedPin.pinnedAt, currentPin.pinnedAt)
    }

    @MainActor
    func testAttachmentExportDoesNotOverwriteExistingFile() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let source = try storeURL().deletingLastPathComponent().appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        let action = SnipCLILibraryAction.addFiles(content: "", list: nil, paths: [source.path])
        let model = AppModel(library: library, defaults: defaults())
        let receipt = try await model.handleCLIRequest(.init(action: .extended(.library(action))))
        let snip = try XCTUnwrap(receipt.snips.first)
        let attachment = try XCTUnwrap(snip.attachments.first)
        let destination = source.deletingLastPathComponent().appendingPathComponent("export.txt")
        let export = SnipCLILibraryAction.exportAttachment(snipID: snip.id, attachmentID: attachment.id, path: destination.path)
        _ = try await model.handleCLIRequest(.init(action: .extended(.library(export))))
        XCTAssertEqual(try Data(contentsOf: destination), Data("source".utf8))
        try Data("keep existing".utf8).write(to: destination)
        do {
            _ = try await model.handleCLIRequest(.init(action: .extended(.library(export))))
            XCTFail("Export must leave an existing destination intact.")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep existing".utf8))
    }

    @MainActor
    func testAttachmentAddRejectsReusedSnipRequestIdentity() async throws {
        let library = try JSONSnipLibrary(fileURL: storeURL())
        let source = try storeURL().deletingLastPathComponent().appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        let model = AppModel(library: library, defaults: defaults())
        let requestID = UUID()
        let first = SnipCLILibraryAction.addFiles(content: "First", list: nil, paths: [source.path])
        _ = try await model.handleCLIRequest(.init(action: .extended(.library(first)), requestID: requestID))
        let changed = SnipCLILibraryAction.addFiles(content: "Changed", list: nil, paths: [source.path])
        do {
            _ = try await model.handleCLIRequest(.init(action: .extended(.library(changed)), requestID: requestID))
            XCTFail("A reused identity must not confirm unrelated existing content.")
        } catch SnipCLIRequestError.conflictingRequestID {}
    }

    @MainActor
    private func add(_ content: String, to library: any SnipLibrary) async throws -> Snip {
        let update = try await library.perform(.add(content: content, origin: .agent, source: nil,
            listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: Date()), sortedBy: .manual)
        guard case .add(.added(let id)) = update.outcome else { throw SnipLibraryError.invalidCommand }
        return try XCTUnwrap(update.snapshot.snips.first { $0.id == id })
    }

    private func reference(_ snip: Snip) -> SnipCLISnipReference {
        .init(id: snip.id, revision: SnipCLIItemRevision.token(snip: snip))
    }
}
