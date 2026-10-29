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
final class IOSSyncModelTests: IOSModelTestCase {
    func testManualSyncUsesTheSameLibraryReplacementAndStatusPathAsLifecycleSync() async {
        let oldLibrary = ModelTestLibrary(
            snips: [Snip(content: "Old collection", origin: .quickEntry)]
        )
        let newLibrary = ModelTestLibrary(
            snips: [Snip(content: "New collection", origin: .quickEntry)]
        )
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .libraryReplaced,
            activeLibrary: newLibrary
        )
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let session = IOSAppSession(
            library: oldLibrary,
            syncedContentSettings: settings,
            cloudSyncSession: cloudSession
        )
        await session.model.load()

        await session.syncWhenPossible()

        XCTAssertEqual(session.model.snips.map(\.content), ["New collection"])
        XCTAssertEqual(settings.mode, .iCloudSync)
        XCTAssertEqual(settings.state, .ready)
        let syncCount = await cloudSession.syncCount()
        XCTAssertEqual(syncCount, 1)
    }

    func testGenerationAdoptionReloadsTheLibraryAndEndsTheSchedulingStatus() async {
        let oldLibrary = ModelTestLibrary(
            snips: [Snip(content: "Old collection", origin: .quickEntry)]
        )
        let adoptedLibrary = ModelTestLibrary(
            snips: [Snip(content: "Adopted collection", origin: .quickEntry)]
        )
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .libraryReplacedAndSyncScheduled,
            activeLibrary: adoptedLibrary
        )
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let session = IOSAppSession(
            library: oldLibrary,
            syncedContentSettings: settings,
            cloudSyncSession: cloudSession
        )
        await session.model.load()

        await session.syncWhenPossible()

        XCTAssertEqual(session.model.snips.map(\.content), ["Adopted collection"])
        XCTAssertEqual(settings.state, .ready)
    }

    func testPurgeReplacesTheLibraryAndExplainsWhySyncStopped() async {
        let oldLibrary = ModelTestLibrary(
            snips: [Snip(content: "Old collection", origin: .quickEntry)]
        )
        let emptyLibrary = ModelTestLibrary(snips: [])
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .iCloudDataReset,
            activeLibrary: emptyLibrary
        )
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let session = IOSAppSession(
            library: oldLibrary,
            syncedContentSettings: settings,
            cloudSyncSession: cloudSession
        )
        await session.model.load()

        await session.syncWhenPossible()

        XCTAssertTrue(session.model.snips.isEmpty)
        XCTAssertEqual(settings.mode, .localOnly)
        XCTAssertEqual(settings.state, .failed(.iCloudDataReset))
        XCTAssertEqual(settings.statusTitle, "Sync turned off")
    }

    func testManualSyncRecordsFailureInSettingsWithoutShowingGeneralError() async {
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .noChange,
            activeLibrary: ModelTestLibrary(),
            syncError: IOSCloudSyncSessionProbe.Failure.offline
        )
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let session = IOSAppSession(
            library: ModelTestLibrary(),
            syncedContentSettings: settings,
            cloudSyncSession: cloudSession
        )

        await session.syncWhenPossible()

        XCTAssertEqual(settings.state, .failed(.appDataIssue))
        XCTAssertFalse(settings.detail.contains("offline"))
        XCTAssertNil(session.model.errorMessage)
    }

    func testSuccessfulRetryClearsThePriorFailureOnlyWhenSyncSettles() async {
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let session = IOSAppSession(
            library: ModelTestLibrary(),
            syncedContentSettings: settings,
            cloudSyncSession: IOSCloudSyncSessionProbe(
                result: .syncCompleted,
                activeLibrary: ModelTestLibrary()
            )
        )
        settings.recordSyncFailure(.retryingSoon)

        await session.retrySyncWhenPossible()

        XCTAssertEqual(settings.state, .ready)
    }

    func testSettledRetryAfterLibraryReplacementReloadsAndClearsFailure() async {
        let adopted = ModelTestLibrary(
            snips: [Snip(content: "Adopted collection", origin: .quickEntry)]
        )
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let session = IOSAppSession(
            library: ModelTestLibrary(),
            syncedContentSettings: settings,
            cloudSyncSession: IOSCloudSyncSessionProbe(
                result: .libraryReplacedAndSyncCompleted,
                activeLibrary: adopted
            )
        )
        settings.recordSyncFailure(.retryingSoon)

        await session.retrySyncWhenPossible()

        XCTAssertEqual(session.model.snips.map(\.content), ["Adopted collection"])
        XCTAssertEqual(settings.state, .ready)
    }

    func testRetryAfterLibraryReplacementReloadsBeforeShowingTheCurrentIssue() async {
        let adopted = ModelTestLibrary(
            snips: [Snip(content: "Adopted with issue", origin: .quickEntry)]
        )
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let session = IOSAppSession(
            library: ModelTestLibrary(),
            syncedContentSettings: settings,
            cloudSyncSession: IOSCloudSyncSessionProbe(
                result: .libraryReplacedWithSyncIssue(.someChangesPending),
                activeLibrary: adopted
            )
        )
        settings.recordSyncFailure(.retryingSoon)

        await session.retrySyncWhenPossible()

        XCTAssertEqual(session.model.snips.map(\.content), ["Adopted with issue"])
        XCTAssertEqual(settings.state, .failed(.someChangesPending))
    }

    func testRetryThatOnlyFetchesKeepsThePriorFailure() async {
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let session = IOSAppSession(
            library: ModelTestLibrary(),
            syncedContentSettings: settings,
            cloudSyncSession: IOSCloudSyncSessionProbe(
                result: .contentUpdated,
                activeLibrary: ModelTestLibrary()
            )
        )
        settings.recordSyncFailure(.retryingSoon)

        await session.retrySyncWhenPossible()

        XCTAssertEqual(settings.state, .failed(.retryingSoon))
    }

    func testAutomaticCloudChangeReloadsTheVisibleLibrary() async {
        let snip = Snip(content: "Before", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [snip])
        let automatic = AsyncStream.makeStream(of: SnipSnapCloudSyncResult.self)
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .noChange,
            activeLibrary: library,
            automaticSyncResults: automatic.stream
        )
        let session = IOSAppSession(library: library, cloudSyncSession: cloudSession)
        await session.model.load()

        await library.replaceText("After", for: snip.id)
        let updated = expectation(description: "Automatic sync updates the visible snips")
        withObservationTracking {
            _ = session.model.snips
        } onChange: {
            updated.fulfill()
        }
        automatic.continuation.yield(.contentUpdated)
        let result = await XCTWaiter.fulfillment(of: [updated], timeout: 2)

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(session.model.snips.first?.content, "After")
    }

    func testAutomaticFetchKeepsWarningUntilTheSyncEngineSettlesIt() async {
        let automatic = AsyncStream.makeStream(of: SnipSnapCloudSyncResult.self)
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .noChange,
            activeLibrary: ModelTestLibrary(),
            automaticSyncResults: automatic.stream
        )
        let session = IOSAppSession(
            library: ModelTestLibrary(),
            syncedContentSettings: settings,
            cloudSyncSession: cloudSession
        )
        settings.recordSyncFailure(.iCloudStorageFull)

        automatic.continuation.yield(.contentUpdated)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(session.syncedContentSettings.state, .failed(.iCloudStorageFull))

        automatic.continuation.yield(.syncCompleted)
        for _ in 0..<50 {
            if session.syncedContentSettings.state == .ready { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.syncedContentSettings.state, .ready)
    }

    func testScheduledSyncEndsItsTransientStatusAndKeepsEarlierFailures() async {
        let automatic = AsyncStream.makeStream(of: SnipSnapCloudSyncResult.self)
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .syncScheduled,
            activeLibrary: ModelTestLibrary(),
            automaticSyncResults: automatic.stream
        )
        let session = IOSAppSession(
            library: ModelTestLibrary(),
            syncedContentSettings: settings,
            cloudSyncSession: cloudSession
        )

        await session.syncWhenPossible()

        XCTAssertEqual(settings.state, .ready)

        settings.recordSyncFailure(.retryingSoon)
        automatic.continuation.yield(.syncScheduled)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(settings.state, .failed(.retryingSoon))
    }

    func testIOSDelayedCancelDoesNotClearNewerBackupPreview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSImportCancelTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("First.json")
        let secondURL = root.appendingPathComponent("Second.json")
        let target = try JSONSnipLibrary(fileURL: root.appendingPathComponent("Target.json"))
        let firstBackup = try JSONSnipLibrary(fileURL: firstURL)
        let secondBackup = try JSONSnipLibrary(fileURL: secondURL)
        _ = try await firstBackup.perform(
            .add(
                content: "First",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        _ = try await secondBackup.perform(
            .add(
                content: "Second",
                origin: .quickEntry,
                source: nil,
                listID: SnipList.inboxID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            ),
            sortedBy: .chronological
        )
        let actions = DirectSnipLibraryUserActions(
            library: target,
            previewBackupImport: { url, library in
                try await SnipLibraryImport.preview(backupURL: url, target: library)
            }
        )
        let session = SavedSnipsSession(library: target, userActions: actions)

        let first = try await session.previewImport(from: firstURL)
        let second = try await session.previewImport(from: secondURL)
        await session.cancelImport(id: first.id)
        let applied = try await session.applyPendingImport(
            id: second.id,
            sortedBy: .chronological
        )

        XCTAssertEqual(applied?.0.snapshot.snips.map(\.content), ["Second"])
    }

    func testSavedSnipsSessionRebindsCommandsAndRecoveryTogether() async throws {
        let oldLibrary = ModelTestLibrary(
            snips: [Snip(content: "Old", origin: .quickEntry)]
        )
        let recoveredValue = Snip(content: "Recovered", origin: .quickEntry)
        let recovered = RecoveredSnip(
            id: recoveredValue.id,
            currentSnipID: recoveredValue.id,
            recovered: recoveredValue,
            conflictingFields: [],
            state: .promoted
        )
        let newLibrary = ModelTestLibrary(
            recovery: SnipRecoverySnapshot(promotedSnips: [recovered])
        )
        let session = SavedSnipsSession(library: oldLibrary)

        let state = await session.withExclusiveAccess { session in
            await session.replaceLibrary(
                newLibrary,
                recoveryScope: SnipRecoveryScope("new-scope"),
                sortedBy: .chronological
            )
        }
        _ = try await session.withExclusiveAccess { session in
            try await session.performUserCommand(
                .add(
                    content: "New",
                    origin: .quickEntry,
                    source: nil,
                    listID: SnipList.inboxID,
                    attachmentURLs: [],
                    requestID: UUID(),
                    now: Date()
                ),
                sortedBy: .chronological
            )
        }

        let oldSnapshot = await oldLibrary.snapshot(sortedBy: .chronological)
        let newSnapshot = await newLibrary.snapshot(sortedBy: .chronological)
        XCTAssertTrue(state.library.snips.isEmpty)
        XCTAssertEqual(state.recovery.promotedSnips, [recovered])
        XCTAssertEqual(oldSnapshot.snips.count, 1)
        XCTAssertEqual(newSnapshot.snips.map(\.content), ["New"])
    }

    func testRoutedComposerSendRejectsSourceDeletedWhileWaitingForMutation() async {
        let work = SnipList(id: UUID(), name: "Work", systemImage: "folder", position: 1)
        let library = ModelTestLibrary(lists: [.inbox, work], suspendsFirstCommand: true)
        let model = makeModel(library: library)
        await model.load()
        let revision = model.libraryRevision
        let delete = Task { await model.deleteList(id: work.id) }
        await library.waitUntilFirstCommandStarts()
        var didStartSend = false
        let send = Task {
            didStartSend = true
            return await model.createSnip(
                content: "Deleted source draft", in: SnipList.inboxID,
                selectCreatedSnip: false, expectedLibraryRevision: revision,
                expectedSourceListID: work.id
            )
        }
        while !didStartSend { await Task.yield() }
        await library.resumeFirstCommand()
        let deleted = await delete.value
        XCTAssertTrue(deleted)
        let saved = await send.value
        XCTAssertFalse(saved)
        XCTAssertEqual(model.libraryRevision, revision)
        XCTAssertTrue(model.snips.isEmpty)
    }

    func testRoutedComposerSendRejectsLibraryReplacementAndPreservesSourceDraft() async throws {
        let oldLibrary = ModelTestLibrary()
        let model = makeModel(library: oldLibrary)
        await model.load()
        let created = await model.createList(name: "Work")
        XCTAssertTrue(created)
        let workID = try XCTUnwrap(model.lists.first { $0.name == "Work" }?.id)
        let suiteName = "RoutedComposerRevisionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let drafts = ComposerDraftStore(defaults: defaults, textDefaultsKey: "drafts")
        drafts.setText("Old Work draft", for: workID)
        let source = drafts.beginSave(listID: workID)
        let revision = model.libraryRevision
        let replacement = ModelTestLibrary()
        await replacement.suspendNextSnapshot()
        let replace = Task { await model.replaceLibrary(replacement, recoveryScope: nil) }
        await replacement.waitUntilSnapshotStarts()
        var didStartSend = false
        let send = Task {
            didStartSend = true
            return await model.createSnip(
                content: source.draft.text, in: SnipList.inboxID,
                selectCreatedSnip: false, expectedLibraryRevision: revision
            )
        }
        while !didStartSend { await Task.yield() }
        await replacement.resumeSnapshot()
        await replace.value
        let saved = await send.value
        drafts.finishSave(source, saved: saved)
        XCTAssertFalse(saved)
        XCTAssertTrue(model.snips.isEmpty)
        XCTAssertEqual(drafts.draft(for: workID).text, "Old Work draft")
    }

    func testRoutedSendRejectsOldPickerRevisionWhenReplacementKeepsListIDs() async {
        let work = SnipList(id: UUID(), name: "Work", systemImage: "folder", position: 1)
        let lists: [SnipList] = [.inbox, work]
        let model = makeModel(library: ModelTestLibrary(lists: lists))
        await model.load()
        let openingRevision = model.libraryRevision
        await model.replaceLibrary(ModelTestLibrary(lists: lists), recoveryScope: nil)

        let staleSaved = await model.createSnip(
            content: "Old picker draft", in: work.id,
            selectCreatedSnip: false, expectedLibraryRevision: openingRevision
        )
        XCTAssertFalse(staleSaved)
        XCTAssertTrue(model.snips.isEmpty)
        let currentSaved = await model.createSnip(
            content: "Current picker draft", in: work.id,
            selectCreatedSnip: false, expectedLibraryRevision: model.libraryRevision
        )
        XCTAssertTrue(currentSaved)
        XCTAssertEqual(model.snips.map(\.content), ["Current picker draft"])
    }

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

    func testLocalToCloudReplacementWaitsForAnEditAndClearsOldUndoRetention() async throws {
        let attachmentID = UUID()
        let attachment = try testAttachment(id: attachmentID, fileName: "local.txt")
        let localSnip = Snip(
            content: "Local content",
            origin: .quickEntry,
            attachments: [attachment]
        )
        let localURL = URL(fileURLWithPath: "/tmp/local.txt")
        let localLibrary = ModelTestLibrary(
            snips: [localSnip],
            attachmentURLs: [attachmentID: localURL],
            suspendsFirstCommand: true
        )
        let cloudSnip = Snip(content: "Cloud content", origin: .quickEntry)
        let cloudLibrary = ModelTestLibrary(snips: [cloudSnip])
        let model = IOSAppModel(
            library: localLibrary,
            initialSnapshot: SnipLibrarySnapshot(
                snips: [localSnip],
                lists: [.inbox],
                attachmentURLs: [attachmentID: localURL]
            )
        )

        let deletion = Task { await model.deleteSnip(id: localSnip.id) }
        await localLibrary.waitUntilFirstCommandStarts()
        let replacement = Task {
            await model.replaceLibrary(cloudLibrary, recoveryScope: nil)
        }
        await localLibrary.resumeFirstCommand()
        let deleted = await deletion.value
        XCTAssertTrue(deleted)
        await replacement.value

        XCTAssertEqual(model.snips, [cloudSnip])
        let localRetentionCalls = await localLibrary.retentionCalls()
        XCTAssertEqual(localRetentionCalls.last, Set<UUID>())
        let cloudRetentionCalls = await cloudLibrary.retentionCalls()
        XCTAssertTrue(cloudRetentionCalls.allSatisfy { !$0.contains(attachmentID) })
    }

    func testAnotherSnipCannotReplaceAnInlineDraftOrItsStagedFiles() async throws {
        let first = Snip(content: "First", origin: .quickEntry)
        let second = Snip(content: "Second", origin: .quickEntry)
        let model = makeModel(library: ModelTestLibrary(snips: [first, second]))
        await model.load()
        XCTAssertTrue(model.beginInlineSnipEdit(first))
        let draft = try XCTUnwrap(model.snipEditorDraft)
        defer { draft.discard() }
        draft.content = "Unsaved first"
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("Keep this attachment".utf8)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        draft.stageMedia(.files([source]), using: model)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while draft.isStaging && clock.now < deadline { await Task.yield() }
        XCTAssertFalse(draft.isStaging)
        let stagedURL = try XCTUnwrap(draft.attachments.first?.url)

        XCTAssertFalse(model.beginInlineSnipEdit(second))
        XCTAssertTrue(model.snipEditorDraft === draft)
        XCTAssertEqual(model.selectedSnipID, first.id)
        XCTAssertTrue(model.beginInlineSnipEdit(first))
        XCTAssertTrue(model.snipEditorDraft === draft)
        XCTAssertEqual(draft.content, "Unsaved first")
        XCTAssertEqual(try Data(contentsOf: stagedURL), bytes)
        let order = model.visibleSnips.map(\.id)
        let reordered = await model.placeVisibleSnips(Array(order.reversed()))
        XCTAssertFalse(reordered)
        XCTAssertEqual(model.visibleSnips.map(\.id), order)
        XCTAssertTrue(model.snipEditorDraft === draft)
        XCTAssertEqual(try Data(contentsOf: stagedURL), bytes)

        model.cancelInlineSnipEdit()
        XCTAssertNil(model.snipEditorDraft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testDiscardedInlineDraftDoesNotExecuteAQueuedSave() async throws {
        let original = Snip(content: "Original", origin: .quickEntry)
        let blocker = Snip(content: "Hold the lock", origin: .quickEntry)
        let library = ModelTestLibrary(snips: [original, blocker], suspendsFirstCommand: true)
        let model = makeModel(library: library)
        await model.load()
        XCTAssertTrue(model.beginInlineSnipEdit(original))
        let draft = try XCTUnwrap(model.snipEditorDraft)
        draft.content = "Discarded edit"

        let blockingEdit = Task { await model.editSnip(blocker, content: "Lock held") }
        await library.waitUntilFirstCommandStarts()
        let save = Task { await draft.save(using: model) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !draft.isSaving && clock.now < deadline { await Task.yield() }
        XCTAssertTrue(draft.isSaving)
        model.finishInlineSnipEdit(draft)
        await library.resumeFirstCommand()

        let blockerSaved = await blockingEdit.value
        let draftSaved = await save.value
        XCTAssertTrue(blockerSaved)
        XCTAssertFalse(draftSaved)
        XCTAssertNil(model.snipEditorDraft)
        XCTAssertEqual(model.snips.first { $0.id == original.id }?.content, "Original")
        let attachmentEdit = await library.lastAttachmentEdit
        XCTAssertNil(attachmentEdit)
    }

    func testLibraryReplacementInvalidatesInlineDraftWithMatchingRecord() async throws {
        let original = Snip(content: "Original", origin: .quickEntry)
        let model = makeModel(library: ModelTestLibrary(snips: [original]))
        await model.load()
        XCTAssertTrue(model.beginInlineSnipEdit(original))
        let draft = try XCTUnwrap(model.snipEditorDraft)
        draft.content = "Old library edit"
        let replacement = ModelTestLibrary(snips: [original])

        await model.replaceLibrary(replacement, recoveryScope: nil)
        let saved = await draft.save(using: model)

        XCTAssertFalse(saved)
        XCTAssertNil(model.snipEditorDraft)
        XCTAssertEqual(model.snips.first { $0.id == original.id }?.content, "Original")
        let attachmentEdit = await replacement.lastAttachmentEdit
        XCTAssertNil(attachmentEdit)
    }

    func testResetReplacementWaitsForAnEditAndDropsItsUndoEntry() async {
        let localLibrary = ModelTestLibrary(suspendsFirstCommand: true)
        let resetLibrary = ModelTestLibrary()
        let model = IOSAppModel(library: localLibrary)

        let creation = Task {
            await model.createSnip(content: "In flight", in: SnipList.inboxID)
        }
        await localLibrary.waitUntilFirstCommandStarts()
        let replacement = Task {
            await model.replaceLibrary(resetLibrary, recoveryScope: nil)
        }
        await localLibrary.resumeFirstCommand()
        let created = await creation.value
        XCTAssertTrue(created)
        await replacement.value

        XCTAssertTrue(model.snips.isEmpty)
    }

    func testRecoveryResolutionWaitsForAnInFlightEdit() async {
        let recoveredValue = Snip(content: "Recovered", origin: .quickEntry)
        let recovered = RecoveredSnip(
            id: recoveredValue.id,
            currentSnipID: recoveredValue.id,
            recovered: recoveredValue,
            conflictingFields: [.text]
        )
        let library = ModelTestLibrary(
            recovery: SnipRecoverySnapshot(pendingSnips: [recovered]),
            suspendsFirstCommand: true
        )
        let model = IOSAppModel(
            library: library,
            recoveryScope: SnipRecoveryScope("cloud")
        )

        let creation = Task {
            await model.createSnip(content: "In flight", in: SnipList.inboxID)
        }
        await library.waitUntilFirstCommandStarts()
        let resolution = Task {
            await model.resolveRecovery(recovered.id, choice: .keepCurrent)
        }
        try? await Task.sleep(for: .milliseconds(20))
        let recoveryStartedWhileEditWasPaused = await library.didRecoveryStart()
        await library.resumeFirstCommand()
        let created = await creation.value
        let resolved = await resolution.value
        XCTAssertTrue(created)
        XCTAssertTrue(resolved)

        XCTAssertFalse(recoveryStartedWhileEditWasPaused)
        let maximumConcurrentOperations = await library.maximumConcurrentOperations()
        XCTAssertEqual(maximumConcurrentOperations, 1)
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
        let settings = SyncedContentSettingsModel(
            mode: .localOnly,
            enableAction: { .enabled }
        )
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

        XCTAssertEqual(model.title, "Sync paused")
        XCTAssertTrue(model.message.contains("stay on this device"))
        XCTAssertFalse(model.showsResolutionActions)
    }

    func testAccountNoticeRefreshReadsTheProductionHandlerSeam() async {
        let handler = IOSAppleAccountCacheHandlerProbe(notices: [.accountChanged, nil])
        let model = AppleAccountNoticeModel(handler: handler)
        let rebinds = IOSAccountLibraryRebindCounter()
        model.setActiveLibraryChangeAction { await rebinds.record() }

        await model.refresh()
        XCTAssertEqual(model.notice, .accountChanged)

        await model.resolve(.remove)
        XCTAssertNil(model.notice)
        let choices = await handler.choices()
        let refreshCount = await handler.refreshCount()
        let rebindCount = await rebinds.value()
        XCTAssertEqual(choices, [.remove])
        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(rebindCount, 2)
    }

    func testReplacingLibraryRefreshesCloudModeInBothDirections() async {
        let id = UUID()
        let localURL = URL(fileURLWithPath: "/tmp/rebound-local.txt")
        let handler = MutableIOSCloudSyncHandler(active: false, states: [:])
        let model = IOSAppModel(
            library: ModelTestLibrary(attachmentURLs: [id: localURL]),
            cloudSyncHandler: handler
        )
        await model.load()
        XCTAssertEqual(model.attachmentURL(for: id), localURL)

        await handler.set(active: true, states: [id: .waiting])
        await model.replaceLibrary(
            ModelTestLibrary(attachmentURLs: [id: localURL]),
            recoveryScope: nil
        )
        XCTAssertTrue(model.isCloudSyncActive)
        XCTAssertNil(model.attachmentURL(for: id))

        await handler.set(active: false, states: [:])
        await model.replaceLibrary(
            ModelTestLibrary(attachmentURLs: [id: localURL]),
            recoveryScope: nil
        )
        XCTAssertFalse(model.isCloudSyncActive)
        XCTAssertEqual(model.attachmentURL(for: id), localURL)
    }

    func testRecoveryResolutionEndsThePreviousFailedUndo() async throws {
        let current = Snip(content: "Current", origin: .quickEntry)
        let recovered = RecoveredSnip(
            id: UUID(), currentSnipID: current.id,
            recovered: Snip(content: "Recovered", origin: .quickEntry), conflictingFields: [.text]
        )
        let library = ModelTestLibrary(
            snips: [current], recovery: SnipRecoverySnapshot(pendingSnips: [recovered]),
            failsReopenOnce: true
        )
        let model = IOSAppModel(library: library, recoveryScope: SnipRecoveryScope("cloud"))
        await model.load()
        _ = await model.toggleDone(id: current.id)
        let undo = try XCTUnwrap(model.toast)
        model.toast = nil
        await model.performToastActionNow(undo)
        let inverseFailure = try XCTUnwrap(model.failure)
        model.presentError(SnipLibraryError.attachmentCopyFailed, operation: "clipboard.write")
        XCTAssertNotNil(model.pendingUndoFailure)

        let resolved = await model.resolveRecovery(recovered.id, choice: .keepCurrent)

        XCTAssertTrue(resolved)
        XCTAssertNil(model.pendingUndoFailure)
        XCTAssertFalse(model.canRetryFailure(inverseFailure))
        await model.performToastActionNow(undo)
        XCTAssertTrue(try XCTUnwrap(model.snips.first { $0.id == current.id }).isDone)
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

private actor IOSAccountLibraryRebindCounter {
    private var count = 0

    func record() { count += 1 }
    func value() -> Int { count }
}
