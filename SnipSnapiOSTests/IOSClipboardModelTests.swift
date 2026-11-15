import Observation
import ImageIO
import SnipSnapCore
import SnipSnapPersistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SnipSnapCloud
@testable import SnipSnapiOS

@MainActor
private final class IOSClipboardGenerationGate {
    private(set) var requestCount = 0
    private let heldRequests: Set<Int>
    private var held: [Int: CheckedContinuation<String?, any Error>] = [:]

    init(holding requests: Set<Int>) {
        heldRequests = requests
    }

    func generation() async throws -> String? {
        requestCount += 1
        let request = requestCount
        guard heldRequests.contains(request) else { return nil }
        return try await withCheckedThrowingContinuation { held[request] = $0 }
    }

    func isHolding(_ request: Int) -> Bool {
        held[request] != nil
    }

    func release(_ request: Int) {
        held.removeValue(forKey: request)?.resume(returning: nil)
    }

    /// The clipboard cloud service rejects an empty generation as unavailable before it uses
    /// CloudKit. A released run that reaches the service while sync is on reports that error.
    func releaseWithEmptyGeneration(_ request: Int) {
        held.removeValue(forKey: request)?.resume(returning: "")
    }
}

/// The saved-snips namespace key the app passes as the clipboard generation, for a new sync
/// generation in one account.
private func clipboardSyncGeneration(account: String = "account-A") -> String {
    let generation = UUID()
    let value = generation.uuidString.lowercased()
    let namespace = ICloudSyncNamespaceBinding(
        scope: "private",
        accountLineage: account,
        generation: generation,
        zones: [
            ICloudSyncZoneBinding(name: "snips-\(value)", ownerName: "_defaultOwner"),
            ICloudSyncZoneBinding(name: "payloads-\(value)", ownerName: "_defaultOwner"),
        ]
    )
    return SnipRecoveryScopeFactory.scope(forActiveCloudNamespace: namespace)!.rawValue
}

/// The sync generation the app reports; a test changes it to adopt a new one.
@MainActor
private final class IOSClipboardSyncGenerationSource {
    var current: String

    init(_ current: String) {
        self.current = current
    }

    func generation() async -> String? { current }
}

/// Holds the first upload, if asked, until the test resumes it; a cancelled run then uploads nothing.
private actor IOSClipboardHeldUploadCloud: ClipboardCloudTransport {
    private var snapshot = ClipboardCloudSnapshot()
    private var holdsNextSave: Bool
    private var heldSave: CheckedContinuation<Void, Never>?

    init(holdsFirstUpload: Bool = true) {
        holdsNextSave = holdsFirstUpload
    }

    var uploadedEntryIDs: Set<UUID> { Set(snapshot.entries.keys) }
    var uploadedTombstoneIDs: Set<UUID> { Set(snapshot.tombstones.keys) }

    /// Waits for the upload to be held. On timeout it stops holding, so no later upload hangs.
    func uploadHeld(within timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while heldSave == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if heldSave == nil { holdsNextSave = false }
        return heldSave != nil
    }

    func resumeUpload() {
        heldSave?.resume()
        heldSave = nil
    }

    func fetch() -> ClipboardCloudSnapshot { snapshot }

    func save(_ incoming: ClipboardCloudSnapshot, cancellation: ClipboardCloudCancellation) async throws {
        if holdsNextSave {
            holdsNextSave = false
            await withCheckedContinuation { heldSave = $0 }
        }
        try cancellation.check()
        snapshot = incoming
    }

    func deleteAll() { snapshot = ClipboardCloudSnapshot() }
}

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

    func testDisablingClipboardSyncDuringAGenerationFetchEndsTheRunAtOnce() async throws {
        let gate = IOSClipboardGenerationGate(holding: [1])
        let model = makeSyncingClipboardModel(gate)
        let stoppedSync = Task { await model.synchronize() }
        try await waitUntil { gate.isHolding(1) }

        await model.setSyncEnabled(false)
        XCTAssertFalse(model.isSyncing)
        XCTAssertFalse(model.syncEnabled)

        await model.setSyncEnabled(true)
        XCTAssertEqual(gate.requestCount, 2)
        gate.releaseWithEmptyGeneration(1)
        await stoppedSync.value
        XCTAssertFalse(model.isSyncing)
        XCTAssertNil(model.syncErrorMessage)
    }

    func testStoppingClipboardSyncDuringAGenerationFetchEndsTheRunAtOnce() async throws {
        let gate = IOSClipboardGenerationGate(holding: [1, 2])
        let model = makeSyncingClipboardModel(gate)
        let stoppedSync = Task { await model.synchronize() }
        try await waitUntil { gate.isHolding(1) }

        model.stop()
        XCTAssertFalse(model.isSyncing)

        let nextSync = Task { await model.synchronize() }
        try await waitUntil { gate.isHolding(2) }
        gate.releaseWithEmptyGeneration(1)
        await stoppedSync.value
        XCTAssertTrue(model.isSyncing)
        XCTAssertNil(model.syncErrorMessage)

        gate.release(2)
        await nextSync.value
        XCTAssertFalse(model.isSyncing)
    }

    func testTurningICloudSyncOffDuringAGenerationFetchShowsNoSyncError() async throws {
        let gate = IOSClipboardGenerationGate(holding: [1])
        let (disableFinished, finishDisable) = AsyncStream<Void>.makeStream()
        let settings = SyncedContentSettingsModel(
            mode: .iCloudSync,
            disableAction: { _ in for await _ in disableFinished {} }
        )
        let model = makeSyncingClipboardModel(gate, settings: settings)
        let sync = Task { await model.synchronize() }
        try await waitUntil { gate.isHolding(1) }

        let disabling = Task.immediate { await settings.disableICloudSync(.useCurrentCache) }
        XCTAssertFalse(model.syncIsActive)
        gate.releaseWithEmptyGeneration(1)
        await sync.value
        XCTAssertFalse(model.isSyncing)
        XCTAssertNil(model.syncErrorMessage)

        finishDisable.finish()
        await disabling.value
    }

    func testTurningICloudSyncOffFromTheStaleCopyAlertStopsTheUploadInFlight() async throws {
        let (disableFinished, finishDisable) = AsyncStream<Void>.makeStream()
        let settings = SyncedContentSettingsModel(
            mode: .iCloudSync,
            initialState: .failed(.iCloudUnavailable),
            disableAction: { _ in for await _ in disableFinished {} }
        )
        let (model, service, cloud) = try await makeUploadingClipboardModel(settings: settings)
        let sync = Task { await model.synchronize() }
        let uploadHeld = await cloud.uploadHeld()
        XCTAssertTrue(uploadHeld, "The upload never started")

        // The alert's Turn off sync button.
        let disabling = Task.immediate { await settings.disableICloudSync(.useCurrentCache) }
        try await waitUntil { !service.isSyncing }
        await cloud.resumeUpload()
        await sync.value

        let uploaded = await cloud.uploadedEntryIDs
        XCTAssertEqual(uploaded, [])
        XCTAssertNil(model.syncErrorMessage)
        finishDisable.finish()
        await disabling.value
    }

    func testDeletingSyncedContentStopsTheUploadInFlight() async throws {
        let (deleteFinished, finishDelete) = AsyncStream<Void>.makeStream()
        let settings = SyncedContentSettingsModel(
            mode: .iCloudSync,
            deleteAction: {
                for await _ in deleteFinished {}
                return .completed
            }
        )
        let (model, service, cloud) = try await makeUploadingClipboardModel(settings: settings)
        let sync = Task { await model.synchronize() }
        let uploadHeld = await cloud.uploadHeld()
        XCTAssertTrue(uploadHeld, "The upload never started")

        let deleting = Task.immediate { await settings.deleteSyncedContent() }
        try await waitUntil { !service.isSyncing }
        await cloud.resumeUpload()
        await sync.value

        let uploaded = await cloud.uploadedEntryIDs
        XCTAssertEqual(uploaded, [])
        XCTAssertNil(model.syncErrorMessage)
        finishDelete.finish()
        await deleting.value
    }

    func testClipboardSyncSetsAsideHistoryAndFollowsANewSyncGeneration() async throws {
        let firstGeneration = clipboardSyncGeneration()
        let secondGeneration = clipboardSyncGeneration()
        let firstCloud = IOSClipboardHeldUploadCloud(holdsFirstUpload: false)
        let secondCloud = IOSClipboardHeldUploadCloud(holdsFirstUpload: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "syncClipboardHistory")
        let source = IOSClipboardSyncGenerationSource(firstGeneration)
        var madeStore: ClipboardHistoryStore?
        let model = IOSClipboardModel(
            rootURL: root,
            settings: SyncedContentSettingsModel(mode: .iCloudSync),
            containerIdentifier: "iCloud.org.example.snipsnap",
            preferences: preferences,
            generation: { await source.generation() },
            makeCloudService: { store, _, syncRootURL in
                madeStore = store
                return ClipboardCloudSyncService(store: store, syncRootURL: syncRootURL,
                                                 makeTransport: { $0 == firstGeneration ? firstCloud : secondCloud })
            }
        )
        let store = try XCTUnwrap(madeStore)
        let older = textEntry("first generation")
        _ = try await store.insert(older)
        await model.synchronize()
        let firstUpload = await firstCloud.uploadedEntryIDs
        XCTAssertEqual(firstUpload, [older.id])

        source.current = secondGeneration
        await model.synchronize()

        XCTAssertNil(model.syncErrorMessage)
        XCTAssertFalse(model.entries.contains { $0.id == older.id })
        let setAside = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("clipboard-quarantine-") }
        XCTAssertEqual(setAside.count, 1)
        let setAsideURL = try XCTUnwrap(setAside.first)
        let setAsideHistory = try await ClipboardHistoryStore(url: setAsideURL).load()
        XCTAssertEqual(setAsideHistory.entries.map(\.id), [older.id])

        let newer = textEntry("second generation")
        _ = try await store.insert(newer)
        await model.synchronize()

        let secondUpload = await secondCloud.uploadedEntryIDs
        XCTAssertEqual(secondUpload, [newer.id])
        XCTAssertNil(model.syncErrorMessage)
    }

    func testAccountResetSetsAsideUnboundClipboardHistoryWhileClipboardSyncIsOn() async throws {
        let older = textEntry("never synced")
        let unbound = try await makeUnboundClipboardModel(holding: [older], syncEnabled: true)
        let model = unbound.model

        await model.resetAccountBinding()
        unbound.source.current = clipboardSyncGeneration(account: "account-B")
        await model.synchronize()

        let uploaded = await unbound.cloud.uploadedEntryIDs
        let uploadedTombstones = await unbound.cloud.uploadedTombstoneIDs
        XCTAssertEqual(uploaded, [])
        XCTAssertEqual(uploadedTombstones, [])
        XCTAssertEqual(model.entries.map(\.id), [])
        let setAside = try await setAsideHistories(in: unbound.root)
        XCTAssertEqual(setAside.map { $0.entries.map(\.id) }, [[older.id]])
        XCTAssertNil(model.syncErrorMessage)
    }

    func testAccountResetKeepsUnboundClipboardHistoryWhileClipboardSyncIsOff() async throws {
        let kept = textEntry("kept while sync is off")
        let unbound = try await makeUnboundClipboardModel(holding: [kept], syncEnabled: false)
        let model = unbound.model

        await model.resetAccountBinding()

        XCTAssertEqual(model.entries.map(\.id), [kept.id])
        let setAside = try await setAsideHistories(in: unbound.root)
        XCTAssertEqual(setAside.count, 0)
        XCTAssertNil(model.syncErrorMessage)
    }

    func testAccountResetKeepsUnboundClipboardHistoryUntilTheUserTurnsClipboardSyncOn() async throws {
        let kept = textEntry("kept while sync is off")
        let unbound = try await makeUnboundClipboardModel(holding: [kept], syncEnabled: false)
        let model = unbound.model

        await model.resetAccountBinding()
        unbound.source.current = clipboardSyncGeneration(account: "account-B")
        await model.synchronize()
        let uploadedWhileOff = await unbound.cloud.uploadedEntryIDs
        XCTAssertEqual(uploadedWhileOff, [])
        XCTAssertEqual(model.entries.map(\.id), [kept.id])

        // The toggle in SnipSnapiOS/SyncedContentSettingsView.swift opens the "Sync clipboard history?"
        // confirmation first; its button calls setSyncEnabled(true), which syncs.
        await model.setSyncEnabled(true)

        let uploaded = await unbound.cloud.uploadedEntryIDs
        XCTAssertEqual(uploaded, [kept.id])
        XCTAssertEqual(model.entries.map(\.id), [kept.id])
        XCTAssertNil(model.syncErrorMessage)
    }

    func testOverlappingClipboardSyncsStartOneRun() async throws {
        let gate = IOSClipboardGenerationGate(holding: [1])
        let model = makeSyncingClipboardModel(gate)
        // Immediate tasks run in call order up to their first suspension, so only the first
        // sync can hold request 1.
        let first = Task.immediate { await model.synchronize() }
        let second = Task.immediate { await model.synchronize() }
        await second.value
        try await waitUntil { gate.isHolding(1) }

        XCTAssertEqual(gate.requestCount, 1)
        XCTAssertTrue(model.isSyncing)

        gate.release(1)
        await first.value
        XCTAssertFalse(model.isSyncing)
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
        model.selectSnips([ordinary.id, pinned.id])
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
        await fulfillment(of: [started], timeout: TestReadiness.timeout)
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

    private func makeSyncingClipboardModel(
        _ gate: IOSClipboardGenerationGate,
        settings: SyncedContentSettingsModel = SyncedContentSettingsModel(mode: .iCloudSync)
    ) -> IOSClipboardModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "syncClipboardHistory")
        return IOSClipboardModel(
            rootURL: root,
            settings: settings,
            containerIdentifier: "iCloud.org.example.snipsnap",
            preferences: preferences,
            generation: { try await gate.generation() }
        )
    }

    /// A model with clipboard sync on and one entry to upload to `cloud`.
    private func makeUploadingClipboardModel(
        settings: SyncedContentSettingsModel
    ) async throws -> (IOSClipboardModel, ClipboardCloudSyncService, IOSClipboardHeldUploadCloud) {
        let cloud = IOSClipboardHeldUploadCloud()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(true, forKey: "syncClipboardHistory")
        var made: (store: ClipboardHistoryStore, service: ClipboardCloudSyncService)?
        let model = IOSClipboardModel(
            rootURL: root,
            settings: settings,
            containerIdentifier: "iCloud.org.example.snipsnap",
            preferences: preferences,
            generation: { "account-generation-A" },
            makeCloudService: { store, _, syncRootURL in
                let service = ClipboardCloudSyncService(store: store, syncRootURL: syncRootURL,
                                                        makeTransport: { _ in cloud })
                made = (store, service)
                return service
            }
        )
        let (store, service) = try XCTUnwrap(made)
        try await store.insert(ClipboardEntry(items: [ClipboardPayloadItem(representations: [
            ClipboardRepresentation(type: UTType.utf8PlainText.identifier, data: Data("stays local".utf8))
        ])]))
        return (model, service, cloud)
    }

    /// A model holding `entries` with no clipboard binding, and clipboard sync on or off. Every
    /// sync generation uploads to the returned cloud.
    private func makeUnboundClipboardModel(
        holding entries: [ClipboardEntry], syncEnabled: Bool
    ) async throws -> (
        model: IOSClipboardModel, root: URL, cloud: IOSClipboardHeldUploadCloud,
        source: IOSClipboardSyncGenerationSource
    ) {
        let cloud = IOSClipboardHeldUploadCloud(holdsFirstUpload: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        preferences.set(syncEnabled, forKey: "syncClipboardHistory")
        let source = IOSClipboardSyncGenerationSource(clipboardSyncGeneration())
        var madeStore: ClipboardHistoryStore?
        let model = IOSClipboardModel(
            rootURL: root,
            settings: SyncedContentSettingsModel(mode: .iCloudSync),
            containerIdentifier: "iCloud.org.example.snipsnap",
            preferences: preferences,
            generation: { await source.generation() },
            makeCloudService: { store, _, syncRootURL in
                madeStore = store
                return ClipboardCloudSyncService(store: store, syncRootURL: syncRootURL, makeTransport: { _ in cloud })
            }
        )
        let store = try XCTUnwrap(madeStore)
        for entry in entries { _ = try await store.insert(entry) }
        await model.load()
        XCTAssertEqual(Set(model.entries.map(\.id)), Set(entries.map(\.id)))
        return (model, root, cloud, source)
    }

    /// Every history set aside in `root`. Each set-aside keeps its own file.
    private func setAsideHistories(in root: URL) async throws -> [ClipboardHistoryState] {
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("clipboard-quarantine-") }
        var histories: [ClipboardHistoryState] = []
        for file in files { histories.append(try await ClipboardHistoryStore(url: file).load()) }
        return histories
    }

    private func textEntry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(items: [ClipboardPayloadItem(representations: [
            ClipboardRepresentation(type: UTType.utf8PlainText.identifier, data: Data(text.utf8))
        ])])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
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
