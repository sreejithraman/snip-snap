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
final class IOSAppModelTests: IOSModelTestCase {
    func testCreateFailureNamesAddWithoutRecordingDraftText() async {
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(library: JSONSnipLibrary.unavailable(), diagnostics: diagnostics.recorder)

        let saved = await model.createSnip(content: "Private draft text", in: SnipList.inboxID)

        XCTAssertFalse(saved)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, "snip.add")
        XCTAssertEqual(diagnostics.events.first?.errorCode, "library.storeUnavailable")
        XCTAssertFalse(diagnostics.events.first?.line.contains("Private") ?? true)
    }

    func testEditFailureNamesUpdateAndKeepsThePresentedError() async {
        let diagnostics = IOSDiagnosticRecorderProbe()
        let model = IOSAppModel(library: JSONSnipLibrary.unavailable(), diagnostics: diagnostics.recorder)
        let snip = Snip(content: "Private original text", origin: .quickEntry)

        let updated = await model.editSnip(snip, content: "Private edited text")

        XCTAssertFalse(updated)
        XCTAssertEqual(model.errorMessage, SnipLibraryError.storeUnavailable.localizedDescription)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, "snip.update")
        XCTAssertEqual(diagnostics.events.first?.errorCode, "library.storeUnavailable")
        XCTAssertFalse(diagnostics.events.first?.line.contains("Private") ?? true)
    }

    func testDeleteFailureNamesDeleteOnce() async {
        let diagnostics = IOSDiagnosticRecorderProbe()
        let snip = Snip(content: "Private deleted text", origin: .quickEntry)
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: [snip], failsDeletion: true),
            diagnostics: diagnostics.recorder)
        await model.load()

        let deleted = await model.deleteSnip(id: snip.id)

        XCTAssertFalse(deleted)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(diagnostics.events.count, 1)
        XCTAssertEqual(diagnostics.events.first?.operation, "snip.delete")
        XCTAssertEqual(diagnostics.events.first?.errorCode, "library.snipNotFound")
        XCTAssertFalse(diagnostics.events.first?.line.contains("Private") ?? true)
    }

    func testUnsupportedListIconKeepsItsSavedChoiceAndVisibleIdentity() {
        let savedSymbol = "snipsnap.future-symbol"
        let list = SnipList(id: UUID(), name: "Future", systemImage: savedSymbol, position: 1)

        XCTAssertEqual(list.displayMark, .letters("F"))
        XCTAssertEqual(list.systemImage, savedSymbol)
        XCTAssertEqual(SnipList.inbox.displayMark, .icon(SnipList.inbox.systemImage))
    }

    func testControlTintUsesTheMonochromeActionPair() throws {
        for (style, fillWhite, labelWhite) in [
            (UIUserInterfaceStyle.light, 0.16, 1.0),
            (.dark, 0.92, 0.10),
        ] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let tint = UIColor(SnipSnapTheme.controlTint).resolvedColor(with: traits)
            let label = UIColor(SnipSnapTheme.actionLabel).resolvedColor(with: traits)
            var tintRed: CGFloat = 0
            var tintGreen: CGFloat = 0
            var tintBlue: CGFloat = 0
            var labelRed: CGFloat = 0
            var labelGreen: CGFloat = 0
            var labelBlue: CGFloat = 0
            XCTAssertTrue(tint.getRed(&tintRed, green: &tintGreen, blue: &tintBlue, alpha: nil))
            XCTAssertTrue(label.getRed(&labelRed, green: &labelGreen, blue: &labelBlue, alpha: nil))
            XCTAssertEqual(tintRed, fillWhite, accuracy: 0.001)
            XCTAssertEqual(tintGreen, fillWhite, accuracy: 0.001)
            XCTAssertEqual(tintBlue, fillWhite, accuracy: 0.001)
            XCTAssertEqual(labelRed, labelWhite, accuracy: 0.001)
            XCTAssertEqual(labelGreen, labelWhite, accuracy: 0.001)
            XCTAssertEqual(labelBlue, labelWhite, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(
                contrastRatio(tint, label),
                4.5,
                "Action controls need readable label contrast in style \(style.rawValue)."
            )
        }
    }

    func testAttachmentDraftCleanupWaitsForChildPresentations() {
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: true,
                isStaging: false,
                isImporting: false,
                isPickingMedia: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: true,
                isImporting: false,
                isPickingMedia: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: true,
                isPickingMedia: false,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPickingMedia: true,
                isPreviewing: false
            )
        )
        XCTAssertFalse(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPickingMedia: false,
                isPreviewing: true
            )
        )
        XCTAssertTrue(
            AttachmentDraftLifecycle.allowsSaving(
                isSaving: false,
                isStaging: false,
                isImporting: false,
                isPickingMedia: false,
                isPreviewing: false
            )
        )
    }

    func testTextSnipFlowCreatesEditsMovesAndDeletes() async throws {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
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
        XCTAssertEqual(model.lastSelectedListID, workID)
        XCTAssertEqual(model.selectedSnip?.listID, workID)

        let deletedSnip = await model.deleteSnip(id: snip.id)
        XCTAssertTrue(deletedSnip)
        XCTAssertTrue(model.snips.isEmpty)
        XCTAssertNil(model.selectedSnipID)
        let pruneCalls = await library.pruneCalls()
        XCTAssertGreaterThan(pruneCalls, 0)
    }

    func testQuickComposerCreateDoesNotChangeTheCurrentSelection() async throws {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()
        let createdList = await model.createList(name: "Work")
        XCTAssertTrue(createdList)
        let workID = try XCTUnwrap(model.lists.first(where: { $0.name == "Work" })?.id)
        model.selectList(SnipList.inboxID)
        model.selectedSnipID = nil

        let created = await model.createSnip(
            content: "Saved in the background",
            in: workID,
            selectCreatedSnip: false
        )

        XCTAssertTrue(created)
        XCTAssertEqual(model.lastSelectedListID, SnipList.inboxID)
        XCTAssertNil(model.selectedSnipID)
        XCTAssertEqual(model.snips.first(where: { $0.content == "Saved in the background" })?.listID, workID)
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
        XCTAssertEqual(model.recoverySnapshot.needsAttentionCount, 1)
        XCTAssertEqual(model.recoverySnapshot.pendingSnips, [recovered])
        await library.replaceText("Changed while open", for: current.id)
        await model.load()
        XCTAssertEqual(model.currentSnip(for: recovered)?.content, "Changed while open")

        let resolved = await model.resolveRecovery(recovered.id, choice: .keepCurrent)
        XCTAssertTrue(resolved)
        let choices = await library.resolutionChoices()
        XCTAssertEqual(choices, [.keepCurrent])
        XCTAssertEqual(model.recoverySnapshot.needsAttentionCount, 0)
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
        let model = makeModel(library: library)
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

    func testCameraPhotoStagesAsAUsableImageAttachment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCameraStagingTests-\(UUID().uuidString)", isDirectory: true)
        defer { AttachmentDraftStager.clean(root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }

        let staged = try await AttachmentMediaStager.stageCameraImage(image, in: root)
        let values = try staged.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        XCTAssertTrue(values.isRegularFile == true)
        XCTAssertFalse(values.isSymbolicLink == true)
        XCTAssertGreaterThan(staged.byteCount, 0)
        XCTAssertNotNil(UIImage(contentsOfFile: staged.url.path))
        XCTAssertTrue(AttachmentImageType.isImage(fileName: staged.fileName))
    }

    func testCancelledCameraPhotoLeavesNoStagedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapCameraCancellationTests-\(UUID().uuidString)", isDirectory: true)
        defer { AttachmentDraftStager.clean(root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AttachmentMediaStager.stageCameraImage(image, in: root)
        }

        do {
            _ = try await task.value
            XCTFail("A cancelled camera import must not publish a staged file.")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testDeleteToastRestoresTheSnipWithoutKeepingSelectionHistory() async throws {
        let library = ModelTestLibrary()
        let model = makeModel(library: library)
        await model.load()
        let didCreate = await model.createSnip(content: "Keep me", in: SnipList.inboxID)
        XCTAssertTrue(didCreate)
        let id = try XCTUnwrap(model.selectedSnipID)

        let didDelete = await model.deleteSnip(id: id)
        XCTAssertTrue(didDelete)
        let toast = try XCTUnwrap(model.toast)
        XCTAssertEqual(toast.message, "Snip deleted")
        XCTAssertEqual(toast.action, .undoDelete)
        XCTAssertFalse(model.snips.contains { $0.id == id })

        await model.performToastActionNow(toast)

        XCTAssertTrue(model.snips.contains { $0.id == id })
        XCTAssertTrue(model.selectedSnipIDs.isEmpty)
        XCTAssertNil(model.toast)
    }

    private func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let lighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: nil) else {
            XCTFail("Action colors must resolve to RGB values.")
            return 0
        }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
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

extension IOSAppModelTests {
    func testCheckedLoadKeepsDurableAddPromptWhileItsRequiredStatusReadIsHeld() async throws {
        let fixture = try IOSCheckedApplicationFixture.make()
        var loadError: (any Error)?
        let load = fixture.start {
            do { _ = try await fixture.model.loadChecked() }
            catch { loadError = error }
        }
        if await fixture.ready(fixture.handler.entered, "required status read") {
            var saved = false
            let add = fixture.start { saved = await fixture.model.createSnip(content: "Durable while checked read waits", in: SnipList.inboxID) }
            if await fixture.prompt(add, "durable add before status release") {
                XCTAssertTrue(saved)
                XCTAssertTrue(fixture.handler.isHeld)
                do {
                    let reopened = try SwiftDataSnipLibrary(storeURL: fixture.storeURL)
                    let durable = try await reopened.checkedSnapshot(sortedBy: .manual)
                    XCTAssertEqual(durable.snips.map(\.content), ["Durable while checked read waits"])
                    XCTAssertEqual(fixture.model.snips.map(\.content), ["Durable while checked read waits"])
                } catch { XCTFail("Independent durable read failed: \(error)") }
                XCTAssertFalse(load.finished.isSet)
            }
            fixture.handler.release()
            if await fixture.prompt(load, "terminal required read error") {
                if let loadError { XCTAssertTrue((loadError as AnyObject) === fixture.handler.failure) }
                else { XCTFail("The required status failure must reach its checked caller") }
                XCTAssertEqual(fixture.handler.maximumConcurrentReads, 1)
                XCTAssertEqual(fixture.handler.readCount, 2, "One coalesced follow-up must read the committed local change")
            }
        }
        await fixture.cleanUp()
    }

    func testCancellingOneCheckedLoadDoesNotCancelItsSharedReadOrAnotherCaller() async throws {
        let fixture = try IOSCheckedApplicationFixture.make()
        var cancelled = false
        var followerError: (any Error)?
        let first = fixture.start {
            do { _ = try await fixture.model.loadChecked(); XCTFail("The cancelled caller cannot return success") }
            catch is CancellationError { cancelled = true }
            catch { XCTFail("Cancellation lost its identity: \(error)") }
        }
        if await fixture.ready(fixture.handler.entered, "shared required read") {
            let follower = fixture.start {
                do { _ = try await fixture.model.loadChecked(); XCTFail("The actual read failure cannot become success") }
                catch { followerError = error }
            }
            first.task.cancel()
            if await fixture.prompt(first, "one cancelled waiter") { XCTAssertTrue(cancelled) }
            XCTAssertTrue(fixture.handler.isHeld)
            XCTAssertEqual(fixture.handler.activeReads, 1)
            XCTAssertFalse(follower.finished.isSet)
            fixture.handler.release()
            if await fixture.prompt(follower, "remaining waiter receives its real terminal read") {
                if let followerError { XCTAssertTrue((followerError as AnyObject) === fixture.handler.failure) }
                else { XCTFail("The remaining waiter must receive the original read failure") }
                XCTAssertEqual(fixture.handler.maximumConcurrentReads, 1)
            }
        }
        await fixture.cleanUp()
    }

    func testHandlerFreeCheckedLoadUsesRealDurableContentAndCheckedRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IOSCheckedLocal-\(UUID())")
        NSLog("IOSCheckedLocal retained store root: %@", root.path)
        let library = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("snips.store"))
        _ = try await library.perform(.add(content: "Literal checked local text", origin: .quickEntry,
            source: nil, listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: .distantPast),
            sortedBy: .manual)
        let model = IOSAppModel(library: library)
        let applied = try await model.loadChecked()
        XCTAssertNil(applied.read.source, "A raw local read stays honestly unbound")
        XCTAssertNil(applied.attachments)
        XCTAssertEqual(model.snips.map(\.content), ["Literal checked local text"])
        XCTAssertTrue(model.recoverySnapshot.pendingSnips.isEmpty)
        XCTAssertTrue(model.recoverySnapshot.pendingLists.isEmpty)
        let reopened = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("snips.store"))
        let durable = try await reopened.checkedSnapshot(sortedBy: .manual)
        XCTAssertEqual(durable.snips.map(\.content), ["Literal checked local text"])
    }
}

private final class IOSCheckedSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var isSet: Bool { lock.withLock { fired } }
    func fire() {
        let pending = lock.withLock {
            fired = true
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        pending.forEach { $0.resume(returning: true) }
    }
    func observe() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Bool? = lock.withLock {
                    if fired { return true }
                    if Task.isCancelled { return false }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: { self.lock.withLock { self.waiters.removeValue(forKey: id) }?.resume(returning: false) }
    }
    func wait(for timeout: Duration) async -> Bool {
        if isSet { return true }
        guard timeout > .zero else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.observe() }
            group.addTask { do { try await Task.sleep(for: timeout) } catch {}; return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

private final class IOSCheckedReadFailure: Error, @unchecked Sendable {}

private final class IOSCheckedStatusHandler: OptionalCloudSyncHandling, @unchecked Sendable {
    let failure = IOSCheckedReadFailure()
    let entered = IOSCheckedSignal()
    private let forwarding: (any OptionalCloudSyncHandling)?

    init(forwarding: (any OptionalCloudSyncHandling)? = nil) { self.forwarding = forwarding }
    private let lock = NSLock()
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var reads = 0
    private var active = 0
    private var maximum = 0
    var readCount: Int { lock.withLock { reads } }
    var activeReads: Int { lock.withLock { active } }
    var maximumConcurrentReads: Int { lock.withLock { maximum } }
    var isHeld: Bool { entered.isSet && lock.withLock { !released } }
    func release() {
        let pending = lock.withLock {
            released = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
    func checkedAttachmentStates() async throws -> SyncedAttachmentReadObservation {
        let first = lock.withLock {
            reads += 1; active += 1; maximum = max(maximum, active)
            return reads == 1
        }
        defer { lock.withLock { active -= 1 } }
        if first {
            // Noncooperative with worker cancellation; only test-owned release ends this read.
            await withCheckedContinuation { pending in
                let finish = lock.withLock {
                    if released { return true }
                    continuation = pending
                    return false
                }
                entered.fire()
                if finish { pending.resume() }
            }
        }
        if let forwarding { return try await forwarding.checkedAttachmentStates() }
        throw failure
    }
    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
    func syncWhenPossible() async {}
    func isCloudSyncActive() async throws -> Bool { false }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] { [:] }
    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL {
        throw SnipLibraryError.attachmentCopyFailed
    }
    func clearDownloadedFiles() async throws {}
}

@MainActor
private final class IOSCheckedApplicationFixture {
    struct Work { let task: Task<Void, Never>; let finished: IOSCheckedSignal }
    let root: URL
    let storeURL: URL
    let model: IOSAppModel
    let handler: IOSCheckedStatusHandler
    private var work: [Work] = []
    private var retainedAfterFailedJoin: IOSCheckedApplicationFixture?
    init(root: URL, library: any SnipLibrary, handler: IOSCheckedStatusHandler = IOSCheckedStatusHandler()) {
        self.root = root
        storeURL = root.appendingPathComponent("snips.store")
        self.handler = handler
        model = IOSAppModel(library: library, cloudSyncHandler: handler)
    }
    static func make() throws -> IOSCheckedApplicationFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IOSCheckedApplication-\(UUID())")
        NSLog("IOSCheckedApplication retained store root: %@", root.path)
        return IOSCheckedApplicationFixture(root: root,
            library: try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("snips.store")))
    }
    func start(_ operation: @escaping @MainActor () async -> Void) -> Work {
        let finished = IOSCheckedSignal()
        let task = Task { await operation(); finished.fire() }
        let owned = Work(task: task, finished: finished)
        work.append(owned)
        return owned
    }
    func ready(_ signal: IOSCheckedSignal, _ stage: String) async -> Bool {
        let ready = await signal.wait(for: .seconds(30))
        XCTAssertTrue(ready, "Checked iOS setup failed: \(stage)")
        return ready
    }
    func prompt(_ owned: Work, _ stage: String) async -> Bool {
        let completed = await owned.finished.wait(for: .seconds(2))
        XCTAssertTrue(completed, "Checked iOS completion failed: \(stage)")
        return completed
    }
    func cleanUp() async {
        handler.release()
        work.forEach { $0.task.cancel() }
        let drainer = start { await self.model.load() }
        let deadline = ContinuousClock.now + .seconds(30)
        var joined = true
        for owned in work {
            let settled = await owned.finished.wait(for: deadline - ContinuousClock.now)
            XCTAssertTrue(settled, "Checked iOS cleanup must join callers and the actual status drainer")
            joined = joined && settled
            if settled { await owned.task.value }
        }
        if joined {
            XCTAssertEqual(handler.activeReads, 0)
            work.removeAll()
        } else {
            drainer.task.cancel()
            retainedAfterFailedJoin = self
            NSLog("IOSCheckedApplication retained live ownership/root: %@", root.path)
        }
    }
}


extension IOSAppModelTests {
    func testActualEnableAppliesItsManagedTargetThroughTheIOSSession() async throws {
        let fixture = try await IOSCheckedEnableFixture.make()
        var result: SyncedContentActionOutcome?
        let operation = fixture.start { result = await fixture.services.syncedContentSettings.enableICloudSyncWithOutcome() }
        if await fixture.completed(operation) {
            if case .completed(let report) = result {
                guard case .success(.iCloudSyncEnabled) = report.origin else {
                    XCTFail("The receipt must retain the actual original enable result")
                    await fixture.cleanUp(); return
                }
                guard case .applied = report.requiredApplication else {
                    XCTFail("Required application must pass through the real iOS model/status owner")
                    await fixture.cleanUp(); return
                }
                XCTAssertEqual(report.operation.status, .succeeded)
                XCTAssertEqual(report.operation.message, "Your snips and attachments sync through iCloud.")
                XCTAssertEqual(fixture.session.model.snips.map(\.content), ["Seed iOS enable"])
                XCTAssertEqual(fixture.session.model.appliedSource?.storageMode, .iCloudSync)
                XCTAssertEqual(fixture.services.syncedContentSettings.mode, .iCloudSync)
                let reopened = SnipLibraryAssembly(library: fixture.source, syncModeRootURL: fixture.modeRoot)
                XCTAssertNotNil(reopened.syncModeStore)
                XCTAssertNotNil(reopened.recoveryScope)
                do {
                    let durable = try await reopened.library.checkedSnapshot(sortedBy: .manual)
                    XCTAssertEqual(durable.snips.map(\.content), ["Seed iOS enable"])
                } catch { XCTFail("Independent managed reopen failed: \(error)") }
            } else { XCTFail("The actual checked enable route must not use a Void success or unsupported fallback") }
        }
        await fixture.cleanUp()
    }

    func testActualEnableKeepsItsOriginalResultWhenRequiredIOSApplicationFails() async throws {
        let fixture = try await IOSCheckedEnableFixture.make()
        let failure = IOSCheckedReadFailure()
        var hookCalls = 0
        fixture.services.syncedContentSettings.setCheckedEnableCompletionAction { _, _ in
            hookCalls += 1
            throw failure
        }
        var result: SyncedContentActionOutcome?
        let operation = fixture.start { result = await fixture.services.syncedContentSettings.enableICloudSyncWithOutcome() }
        if await fixture.completed(operation) {
            XCTAssertEqual(hookCalls, 1)
            if case .completed(let report) = result {
                guard case .success(.iCloudSyncEnabled) = report.origin else {
                    XCTFail("Required application failure cannot replace the actual original backend result")
                    await fixture.cleanUp(); return
                }
                guard case .failed(let error) = report.requiredApplication else {
                    XCTFail("An actual required hook failure cannot become optional current-proof loss")
                    await fixture.cleanUp(); return
                }
                XCTAssertTrue((error as? IOSCheckedReadFailure) === failure)
                XCTAssertEqual(report.operation.status, .failed)
                XCTAssertNil(fixture.session.model.appliedSource)
                let reopened = SnipLibraryAssembly(library: fixture.source, syncModeRootURL: fixture.modeRoot)
                XCTAssertNotNil(reopened.syncModeStore)
                XCTAssertNotNil(reopened.recoveryScope, "The original enable really switched storage before the hook failed")
            } else { XCTFail("The original enabled value and real required hook error must remain distinguishable") }
        }
        await fixture.cleanUp()
    }

    func testDeadIOSOutcomeBridgeDoesNotTurnMissingApplicationIntoVoidSuccess() async throws {
        let bridge = IOSCloudSyncActionBridge()
        let result = try await bridge.retrySyncWithOutcome()
        guard case .notRun(.unavailableSession) = result else {
            return XCTFail("A dead weak application owner cannot produce an admitted receipt")
        }
    }
}

@MainActor
private final class IOSCheckedEnableFixture {
    struct Work { let task: Task<Void, Never>; let finished: IOSCheckedSignal }
    let root: URL
    let modeRoot: URL
    let source: SwiftDataSnipLibrary
    let services: SnipSnapCloudAppServices
    let session: IOSAppSession
    let handler: AppleAccountCacheCoordinatorHandler?
    private var work: [Work] = []
    private var retainedAfterFailedJoin: IOSCheckedEnableFixture?

    private init(
        root: URL, source: SwiftDataSnipLibrary, services: SnipSnapCloudAppServices, session: IOSAppSession,
        handler: AppleAccountCacheCoordinatorHandler?
    ) {
        self.root = root; self.modeRoot = root.appendingPathComponent("mode")
        self.source = source; self.services = services; self.session = session; self.handler = handler
    }

    static func make() async throws -> IOSCheckedEnableFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IOSCheckedEnable-\(UUID())")
        NSLog("IOSCheckedEnable retained store root: %@", root.path)
        let source = try SwiftDataSnipLibrary(storeURL: root.appendingPathComponent("source/snips.store"))
        _ = try await source.perform(.add(content: "Seed iOS enable", origin: .quickEntry, source: nil,
            listID: SnipList.inboxID, attachmentURLs: [], requestID: UUID(), now: .distantPast), sortedBy: .manual)
        let services = SnipSnapCloudAppAssembly.simulatedLocalOnlyServices(rootURL: root.appendingPathComponent("mode"), sourceLibrary: source)
        let bridge = IOSCloudSyncActionBridge()
        let handler = services.makeAccountCacheHandler(syncWhenPossible: { await bridge.syncWhenPossible() },
            retrySyncWhenPossible: { await bridge.retrySyncWhenPossible() },
            retrySyncWithOutcome: { try await bridge.retrySyncWithOutcome() },
            scheduleSyncAfterLocalChange: { await bridge.scheduleSyncAfterLocalChange() })
        let session = IOSAppSession(library: source, syncedContentSettings: services.syncedContentSettings,
            cloudSyncSession: services.syncSession, cloudSyncHandler: handler,
            clipboardRootURL: root.appendingPathComponent("clipboard"))
        bridge.session = session
        return IOSCheckedEnableFixture(root: root, source: source, services: services, session: session, handler: handler)
    }

    func start(_ operation: @escaping @MainActor () async -> Void) -> Work {
        let signal = IOSCheckedSignal()
        let task = Task { await operation(); signal.fire() }
        let owned = Work(task: task, finished: signal)
        work.append(owned)
        return owned
    }

    func completed(_ owned: Work) async -> Bool {
        let completed = await owned.finished.wait(for: .seconds(30))
        XCTAssertTrue(completed, "Actual enable/setup and required application must finish before inspection")
        return completed
    }

    func cleanUp() async {
        work.forEach { $0.task.cancel() }
        _ = start { await self.session.model.load() }
        let deadline = ContinuousClock.now + .seconds(30)
        var joined = true
        for owned in work {
            let settled = await owned.finished.wait(for: deadline - ContinuousClock.now)
            XCTAssertTrue(settled, "Enable cleanup must join callers and the existing model status owner")
            joined = joined && settled
            if settled { await owned.task.value }
        }
        if joined { work.removeAll() }
        else {
            retainedAfterFailedJoin = self
            NSLog("IOSCheckedEnable retained live ownership/root: %@", root.path)
        }
    }
}

extension IOSAppModelTests {
    func testActualNormalSchedulingEndsWithoutEngineDeliveryAndAllowsAnotherExplicitRetry() async throws {
        let fixture = try await IOSCheckedEnableFixture.make()
        do {
            let services = fixture.services
            let backend = try XCTUnwrap(services.syncSession)
            let handler = try XCTUnwrap(fixture.handler)
            let settings = services.syncedContentSettings
            let operation = fixture.start {
                guard case .completed(let enable) = await settings.enableICloudSyncWithOutcome(),
                      enable.operation.status == .succeeded else {
                    return XCTFail("Real mode enable must succeed before exercising an active schedule")
                }
                do {
                    let scheduled = try await backend.synchronizeWithTarget()
                    XCTAssertEqual(scheduled.result, .syncScheduled)
                    XCTAssertNotNil(scheduled.target)
                    // The simulated service supplies no automatic delivery stream.
                    await handler.syncWhenPossible()
                    XCTAssertTrue(settings.canSyncNow)
                    XCTAssertEqual(settings.state, .ready)

                    settings.recordSyncFailure(.waitingForConnection)
                    await handler.syncWhenPossible()
                    XCTAssertEqual(settings.state, .failed(.waitingForConnection))
                    XCTAssertTrue(settings.canSyncNow)

                    guard case .completed(let retry) = try await handler.retrySyncWithOutcome() else {
                        return XCTFail("The actual handler and Core must admit the next explicit retry")
                    }
                    XCTAssertEqual(retry.operation.status, .succeeded)
                    guard case .applied = retry.requiredApplication else {
                        return XCTFail("The explicit retry still awaits its real required application")
                    }
                    XCTAssertEqual(fixture.session.model.snips.map(\.content), ["Seed iOS enable"])
                } catch { XCTFail("Actual scheduling or retry failed: \(error)") }
            }
            _ = await fixture.completed(operation)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    func testDifferentSameStoreApplicationCannotCompleteSupersededIOSCohort() async throws {
        let enabled = try await IOSCheckedEnableFixture.make()
        let settings = enabled.services.syncedContentSettings
        var outcome: SyncedContentActionOutcome?
        let enable = enabled.start { outcome = await settings.enableICloudSyncWithOutcome() }
        guard await enabled.completed(enable) else { await enabled.cleanUp(); return }
        guard case .completed(let report) = outcome, report.operation.status == .succeeded else {
            XCTFail("The real managed source must be enabled before the cohort test")
            await enabled.cleanUp()
            return
        }
        do {
            let backend = try XCTUnwrap(enabled.services.syncSession)
            let handler = try XCTUnwrap(enabled.handler)
            let firstValue = try await backend.currentApplicationTarget()
            let secondValue = try await backend.currentApplicationTarget()
            let firstTarget = try XCTUnwrap(firstValue?.application)
            let secondTarget = try XCTUnwrap(secondValue?.application)
            XCTAssertEqual(firstTarget.source, secondTarget.source)
            XCTAssertFalse(firstTarget === secondTarget)
            let probe = IOSCheckedStatusHandler(forwarding: handler)
            let fixture = IOSCheckedApplicationFixture(root: enabled.root, library: firstTarget.library, handler: probe)
            let firstSettings = SyncedContentSettingsModel(mode: .localOnly)
            let start = firstSettings.recordSyncStarted()
            let completion = IOSAppModel.SyncApplicationCompletion(
                settings: firstSettings, clipboard: enabled.session.clipboard, start: start, enabling: true)
            var firstError: (any Error)?
            let first = fixture.start {
                do {
                    _ = try await fixture.model.applyChecked(firstTarget, completion: completion)
                    XCTFail("A supplanted cohort cannot borrow its successor's attachment frame")
                } catch { firstError = error }
            }
            if await fixture.ready(probe.entered, "original required attachment read") {
                let secondDispatched = IOSCheckedSignal()
                let second = fixture.start {
                    secondDispatched.fire()
                    do { _ = try await fixture.model.applyChecked(secondTarget) }
                    catch { XCTFail("Second target should apply its real checked result: \(error)") }
                }
                if await fixture.ready(secondDispatched, "second target dispatched") {
                    let followerDispatched = IOSCheckedSignal()
                    let follower = fixture.start {
                        followerDispatched.fire()
                        do { _ = try await fixture.model.applyChecked(secondTarget) }
                        catch { XCTFail("Same-target checked follower failed: \(error)") }
                    }
                    if await fixture.ready(followerDispatched, "same-target follower dispatched") {
                        XCTAssertTrue(probe.isHeld)
                        XCTAssertFalse(first.finished.isSet)
                        XCTAssertFalse(second.finished.isSet)
                        XCTAssertFalse(follower.finished.isSet)
                        probe.release()
                        if await fixture.prompt(first, "superseded target rejected"),
                           await fixture.prompt(second, "second target applied"),
                           await fixture.prompt(follower, "same-target follower delivered") {
                            XCTAssertTrue(firstError is SnipLibraryReadPublicationError)
                            XCTAssertEqual(firstSettings.mode, .localOnly)
                            XCTAssertEqual(probe.readCount, 2)
                            XCTAssertEqual(probe.maximumConcurrentReads, 1)
                            XCTAssertEqual(fixture.model.snips.map(\.content), ["Seed iOS enable"])
                        }
                    }
                }
            }
            await fixture.cleanUp()
        } catch {
            await enabled.cleanUp()
            throw error
        }
        await enabled.cleanUp()
    }
}

@MainActor
final class IOSDoneLimitTests: IOSModelTestCase {
    private func displayDefaults() -> UserDefaults {
        let suite = "done-limit-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func doneSnips(in listID: UUID = SnipList.inboxID) -> [Snip] {
        (1...12).map {
            Snip(createdAt: Date(timeIntervalSince1970: Double($0)), content: "Done \($0)", origin: .agent,
                 listID: listID, isDone: true, manualPosition: Int64($0))
        }
    }

    func testDefaultLimitPreservesNotDoneAndPinnedSnipsAndPersistsUnlimited() async {
        let settings = displayDefaults()
        let done = doneSnips()
        let pending = Snip(content: "Not Done", origin: .quickEntry)
        let pin = Snip(content: "Pinned", origin: .quickEntry, pinnedAt: Date(timeIntervalSince1970: 1))
        let library = ModelTestLibrary(snips: done + [pending, pin])
        let model = IOSAppModel(library: library, defaults: settings)
        await model.load()
        XCTAssertEqual(model.doneLimit, .ten)
        XCTAssertEqual(model.visibleSnips.map(\.id), [pin.id, pending.id] + done[2...].reversed().map(\.id))
        model.setDoneLimit(.unlimited)
        let reopened = IOSAppModel(library: library, defaults: settings)
        await reopened.load()
        XCTAssertEqual(reopened.doneLimit, .unlimited)
        XCTAssertEqual(reopened.visibleSnips.count, 14)
    }

    func testLimitFollowsListOriginAndSortWhileSearchBypassesIt() async {
        let work = SnipList(id: UUID(), name: "Work", systemImage: "folder", position: 1)
        let done = doneSnips()
        let elsewhere = doneSnips(in: work.id)
        let humans = (1...12).map { Snip(content: "Human \($0)", origin: .quickEntry, isDone: true) }
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: done + elsewhere + humans, lists: [.inbox, work]), defaults: displayDefaults()
        )
        await model.load()
        model.originFilter = .agent
        XCTAssertEqual(model.visibleSnips.map(\.id), done[2...].reversed().map(\.id))
        XCTAssertEqual(model.visibleSnips(in: work.id).map(\.id), elsewhere[2...].reversed().map(\.id))
        model.sortMode = .manual
        XCTAssertEqual(model.visibleSnips.map(\.id), Array(done.prefix(10)).map(\.id))
        model.sortMode = .oldestFirst
        XCTAssertEqual(model.visibleSnips.map(\.id), Array(done.prefix(10)).map(\.id))
        model.searchText = "Done"
        XCTAssertEqual(model.visibleSnips.map(\.id), done.map(\.id))
        model.completionFilter = .notDone
        XCTAssertTrue(model.visibleSnips.isEmpty, "iOS keeps its existing completion filter during list search")
        model.completionFilter = .done
        XCTAssertEqual(model.visibleSnips.count, 12)
        model.searchText = " \n "
        XCTAssertEqual(model.visibleSnips.count, 12)
        XCTAssertEqual(model.doneLimit, .ten)
        model.completionFilter = .all
        XCTAssertEqual(model.visibleSnips.count, 10)
        XCTAssertFalse(model.canReorderVisibleSnips)
    }

    func testShrinkingLimitKeepsVisibleSelectionAcrossListsAndAnEditorMounted() async {
        let done = doneSnips()
        let work = SnipList(id: UUID(), name: "Work", systemImage: "folder", position: 1)
        let other = Snip(content: "Elsewhere", origin: .quickEntry, listID: work.id)
        let model = IOSAppModel(
            library: ModelTestLibrary(snips: done + [other], lists: [.inbox, work]), defaults: displayDefaults()
        )
        await model.load()
        model.setDoneLimit(.unlimited)
        model.selectSnips([done[0].id, done[11].id, other.id])
        model.setDoneLimit(.ten)
        XCTAssertEqual(model.selectedSnipIDs, [done[11].id, other.id])
        model.setDoneLimit(.unlimited)
        XCTAssertTrue(model.beginInlineSnipEdit(done[0]))
        let draft = model.snipEditorDraft
        model.setDoneLimit(.ten)
        XCTAssertEqual(model.doneLimit, .unlimited)
        XCTAssertTrue(model.snipEditorDraft === draft)
        XCTAssertTrue(model.visibleSnips.contains { $0.id == done[0].id })
    }

    func testDoneStatusKeepsEveryMatchingDoneSnipSelectedUntilReturningToAll() async {
        let done = doneSnips()
        let settings = displayDefaults()
        let model = IOSAppModel(library: ModelTestLibrary(snips: done), defaults: settings)
        await model.load()
        model.completionFilter = .done
        XCTAssertEqual(model.visibleSnips.count, 12)
        model.selectSnips([done[0].id, done[11].id])
        model.sortMode = .oldestFirst
        XCTAssertEqual(model.selectedSnipIDs, [done[0].id, done[11].id])
        XCTAssertEqual(SnipDoneLimit.load(from: settings), .ten)
        model.completionFilter = .all
        XCTAssertEqual(model.selectedSnipIDs, [done[0].id])
        XCTAssertEqual(model.visibleSnips.count, 10)
    }

    func testSortChangeRemovesOnlySelectionHiddenByTheDoneLimit() async {
        let done = doneSnips()
        let human = Snip(content: "Gathered human", origin: .quickEntry)
        let model = IOSAppModel(library: ModelTestLibrary(snips: done + [human]), defaults: displayDefaults())
        await model.load()
        model.selectSnips([done[11].id, done[5].id, human.id])
        model.originFilter = .agent
        model.sortMode = .manual
        XCTAssertEqual(model.selectedSnipIDs, [done[5].id, human.id])
        model.setDoneLimit(.unlimited)
        XCTAssertEqual(model.selectedSnipIDs, [done[5].id, human.id])
    }

    func testDoneMutationAndReloadDropSelectionThatFallsPastTheLimit() async {
        let done = doneSnips()
        let pending = Snip(createdAt: Date(timeIntervalSince1970: 100), content: "Next Done", origin: .agent)
        let library = ModelTestLibrary(snips: done + [pending])
        let model = IOSAppModel(library: library, defaults: displayDefaults())
        await model.load()
        model.selectSnips([done[2].id, done[11].id])
        let changed = await model.toggleDone(id: pending.id)
        XCTAssertTrue(changed)
        XCTAssertEqual(model.selectedSnipIDs, [done[11].id])
        await model.load()
        XCTAssertEqual(model.selectedSnipIDs, [done[11].id])
    }
    func testLiveDoneChangeKeepsEditorMountedUntilCancellation() async {
        let done = doneSnips()
        let pending = Snip(createdAt: Date(timeIntervalSince1970: 100), content: "Next Done", origin: .agent)
        let model = IOSAppModel(library: ModelTestLibrary(snips: done + [pending]), defaults: displayDefaults())
        await model.load()
        XCTAssertTrue(model.beginInlineSnipEdit(done[2]))
        let draft = model.snipEditorDraft
        let changed = await model.toggleDone(id: pending.id)
        XCTAssertTrue(changed)
        XCTAssertTrue(model.snipEditorDraft === draft)
        XCTAssertTrue(model.visibleSnips.contains { $0.id == done[2].id })
        model.cancelInlineSnipEdit()
        XCTAssertFalse(model.visibleSnips.contains { $0.id == done[2].id })
        XCTAssertNil(model.selectedSnipID)
    }

    func testClearingSearchReappliesLimitToGatheredAndSingleSelection() async {
        let done = doneSnips()
        let model = IOSAppModel(library: ModelTestLibrary(snips: done), defaults: displayDefaults())
        await model.load()
        model.searchText = "Done"
        model.selectSnips([done[0].id, done[11].id])
        model.selectedSnipID = done[0].id
        model.searchText = ""
        XCTAssertEqual(model.selectedSnipIDs, [done[11].id])
        XCTAssertNil(model.selectedSnipID)
    }

}
