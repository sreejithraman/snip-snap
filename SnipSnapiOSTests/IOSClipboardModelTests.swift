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
final class IOSClipboardModelTests: IOSModelTestCase {
    func testClipboardSyncPreferenceDoesNotImplyMainSyncIsActive() {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "syncClipboardHistory")
        let settings = SyncedContentSettingsModel(mode: .localOnly)
        let model = IOSClipboardModel(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), settings: settings, preferences: preferences)
        XCTAssertTrue(model.syncEnabled)
        XCTAssertFalse(model.syncIsActive)
    }

    func testClipboardImportFailureStaysVisibleUntilQueueRetrySucceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let imports = ShareClipboardImportStore(sharedRootURL: root)
        let request = ShareImportRequest(content: "Retry this", destinationListID: SnipList.inboxID)
        let ready = root.appendingPathComponent(
            "Share/ClipboardImports/\(request.requestID.uuidString).ready"
        )
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: ready.appendingPathComponent("clipboard.json"))
        let history = root.appendingPathComponent("clipboard.json")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let model = IOSClipboardModel(rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await model.foreground()
        XCTAssertNotNil(model.importErrorMessage)
        await model.synchronize()
        XCTAssertNotNil(model.importErrorMessage)
        try FileManager.default.removeItem(at: history)
        await model.foreground()
        XCTAssertNil(model.importErrorMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entries.map(\.text), ["Retry this"])
        let pending = await imports.pendingImportCount()
        XCTAssertEqual(pending, 0)
    }

    func testClipboardLoadFailureRecordsOncePerVisibleFailureEpisode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("clipboard.json")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSClipboardModel(
            rootURL: root,
            settings: SyncedContentSettingsModel(mode: .localOnly),
            preferences: UserDefaults(suiteName: UUID().uuidString)!,
            diagnostics: diagnostics.recorder
        )

        await model.load()
        await model.load()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, "clipboard.load")
        XCTAssertEqual(diagnostics.events.first?.visibility, .user)

        try FileManager.default.removeItem(at: history)
        await model.load()
        XCTAssertNil(model.errorMessage)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        await model.load()
        XCTAssertEqual(diagnostics.events.count, 2)
    }

    func testPinnedSnipsStayFirstAndCannotBeMarkedDone() async {
        let pinned = Snip(content: "Reusable", origin: .quickEntry, pinnedAt: Date())
        let ordinary = Snip(content: "Task", origin: .quickEntry)
        let model = makeModel(library: ModelTestLibrary(snips: [ordinary, pinned]))
        await model.load()
        XCTAssertEqual(model.visibleSnips.first?.id, pinned.id)
        let reordered = await model.placeVisibleSnips([ordinary.id, pinned.id])
        XCTAssertFalse(reordered)
        let changed = await model.toggleDone(id: pinned.id)
        XCTAssertFalse(changed)
        model.selectedSnipIDs = [ordinary.id, pinned.id]
        _ = await model.setSelectionDone(true)
        XCTAssertFalse(model.snips.first { $0.id == pinned.id }!.isDone)
        XCTAssertTrue(model.snips.first { $0.id == ordinary.id }!.isDone)
    }

    func testClipboardPasteAcceptsAdvertisedHEICRepresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = NSItemProvider()
        let bytes = Data("provider HEIC bytes".utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.heic.identifier, visibility: .all) { completion in
            completion(bytes, nil)
            return nil
        }
        let model = IOSClipboardModel(rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await model.capture([provider])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entries.first?.imageRepresentations.first?.data, bytes)
    }

    func testUnreadableTextPasteDoesNotBecomeCloudOrFileError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IOSClipboardModel(rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let text = NSItemProvider(object: "Keep this text" as NSString)
        await model.capture([text])
        let savedIDs = model.entries.map(\.id)
        XCTAssertEqual(model.entries.first?.text, "Keep this text")
        let unreadableText = NSItemProvider()
        unreadableText.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        await model.capture([unreadableText])
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.pasteErrorMessage?.contains("clipboard") == true)
        XCTAssertEqual(model.entries.map(\.id), savedIDs)
        await model.synchronize()
        XCTAssertNotNil(model.pasteErrorMessage)
        model.dismissPasteError()
        XCTAssertNil(model.pasteErrorMessage)
        await model.capture([])
        XCTAssertNotNil(model.pasteErrorMessage)
        XCTAssertNil(model.errorMessage)
        await model.capture([text])
        XCTAssertNil(model.pasteErrorMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entries.first?.text, "Keep this text")
    }

    func testClipboardEmptyAndUnsupportedPasteHaveDistinctMessages() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IOSClipboardModel(rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await model.capture([])
        XCTAssertEqual(model.pasteErrorMessage, "There’s nothing to paste. Copy text or an image, then try again.")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { completion in
            completion(Data("PDF".utf8), nil)
            return nil
        }
        await model.capture([provider])
        XCTAssertEqual(model.pasteErrorMessage, "This clipboard content isn’t supported. Try copying text or an image.")
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testClipboardIgnoresAnotherPasteWhileProviderIsLoading() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IOSClipboardModel(rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let started = expectation(description: "Provider began loading")
        let release = DispatchSemaphore(value: 0)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.html.identifier, visibility: .all) { completion in
            started.fulfill()
            DispatchQueue.global().async {
                release.wait()
                completion(Data("<p>First paste</p>".utf8), nil)
            }
            return nil
        }
        let firstPaste = Task { await model.capture([provider]) }
        await fulfillment(of: [started], timeout: 2)
        await model.capture([NSItemProvider(object: "Second paste" as NSString)])
        release.signal()
        await firstPaste.value
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.text, "First paste")
    }

    func testRichTextOnlyClipboardPayloadHasTextForPreviewAndSearch() throws {
        let richText = NSAttributedString(string: "Rich clipboard text")
        let rtf = try richText.data(from: NSRange(location: 0, length: richText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rtfItem = ClipboardPayloadItem(representations: [ClipboardRepresentation(type: UTType.rtf.identifier, data: rtf)])
        XCTAssertEqual(IOSClipboardModel.previewText(from: [rtfItem]), "Rich clipboard text")
        let htmlItem = ClipboardPayloadItem(representations: [ClipboardRepresentation(type: UTType.html.identifier, data: Data("<p>Read <b>this</b></p>".utf8))])
        XCTAssertEqual(IOSClipboardModel.previewText(from: [htmlItem]), "Read this")
        XCTAssertEqual(rtfItem.representations.first?.data, rtf)
    }

    func testClipboardPinActionUsesCurrentStateAfterRowChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(url: root.appendingPathComponent("clipboard.json"))
        let original = ClipboardEntry(items: [ClipboardPayloadItem(representations: [
            ClipboardRepresentation(type: UTType.utf8PlainText.identifier, data: Data("Reuse".utf8))
        ])])
        _ = try await store.insert(original)
        let model = IOSClipboardModel(rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly), preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await model.load()
        await model.togglePin(original)
        XCTAssertTrue(model.entries.first!.isPinned)
        await model.togglePin(original)
        XCTAssertFalse(model.entries.first!.isPinned)
    }

    func testClipboardClearKeepsPinsAndDeleteRemovesThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(url: root.appendingPathComponent("clipboard.json"))
        let entry = ClipboardEntry(items: [ClipboardPayloadItem(representations: [
            ClipboardRepresentation(type: UTType.utf8PlainText.identifier, data: Data("Keep".utf8))
        ])], pinnedAt: Date())
        _ = try await store.insert(entry)
        _ = try await store.insert(ClipboardEntry(items: [ClipboardPayloadItem(representations: [
            ClipboardRepresentation(type: UTType.utf8PlainText.identifier, data: Data("Clear".utf8))
        ])]))
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let model = IOSClipboardModel(rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly), preferences: preferences)
        await model.load()
        XCTAssertFalse(model.syncEnabled)
        await model.clear()
        XCTAssertEqual(model.entries.map(\.id), [entry.id])
        await model.delete(entry)
        XCTAssertTrue(model.entries.isEmpty)
        let saved = try await store.load()
        XCTAssertNotNil(saved.tombstones[entry.id])
    }

    func testClipboardOperationFailureDoesNotBecomeASyncRetryNotice() {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let clipboard = IOSClipboardModel(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            settings: SyncedContentSettingsModel(mode: .localOnly), preferences: preferences
        )

        clipboard.presentError(SnipLibraryError.storeUnavailable, operation: "clipboard.pin", message: "Couldn’t update the pin. Try again.")

        XCTAssertEqual(clipboard.operationFailure?.operation, "clipboard.pin")
        XCTAssertEqual(clipboard.errorMessage, "Couldn’t update the pin. Try again.")
        XCTAssertNil(clipboard.persistentErrorMessage)
        XCTAssertNil(clipboard.syncErrorMessage)
    }

    func testResolvedClipboardFailureClearsOnlyItsIncidentAndKeepsUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clipboard = IOSClipboardModel(
            rootURL: root, settings: SyncedContentSettingsModel(mode: .localOnly),
            preferences: UserDefaults(suiteName: UUID().uuidString)!
        )
        let model = IOSAppModel(library: ModelTestLibrary())
        let undo = AppToast.deleted(count: 1, id: UUID())
        model.presentToast(undo)
        clipboard.presentError(SnipLibraryError.storeUnavailable, operation: "clipboard.clear", message: "Couldn’t clear clipboard history.")
        let incident = try XCTUnwrap(clipboard.operationFailure)
        model.presentFailure(incident)
        XCTAssertEqual(model.inlineFailure?.id, incident.id)

        await clipboard.clear()
        XCTAssertNil(clipboard.operationFailure)
        model.clearFailure(id: incident.id)
        XCTAssertNil(model.inlineFailure)
        XCTAssertEqual(model.toast?.id, undo.id)
        XCTAssertEqual(model.latestFailure?.id, incident.id)

        model.presentError("A newer failure", operation: "clipboard.write", diagnosticCode: "pasteboard.writeFailed")
        let newerID = model.failure?.id
        model.clearFailure(id: incident.id)
        XCTAssertEqual(model.failure?.id, newerID)
        XCTAssertEqual(model.toast?.id, undo.id)
    }

}
