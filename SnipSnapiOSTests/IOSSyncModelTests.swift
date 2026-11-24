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
    func testManualSyncShowsTheEnabledCloudLibraryAndSettles() async {
        let oldLibrary = ModelTestLibrary(
            snips: [Snip(content: "Old collection", origin: .quickEntry)]
        )
        let newLibrary = ModelTestLibrary(
            snips: [Snip(content: "New collection", origin: .quickEntry)]
        )
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .iCloudSyncEnabled,
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

    func testPurgeKeepsTheLibraryAndExplainsWhySyncStopped() async {
        let snip = Snip(content: "Kept snip", origin: .quickEntry)
        let oldLibrary = ModelTestLibrary(snips: [snip])
        let localLibrary = ModelTestLibrary(snips: [snip])
        let cloudSession = IOSCloudSyncSessionProbe(
            result: .iCloudDataReset,
            activeLibrary: localLibrary
        )
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let session = IOSAppSession(
            library: oldLibrary,
            syncedContentSettings: settings,
            cloudSyncSession: cloudSession
        )
        await session.model.load()

        await session.syncWhenPossible()

        XCTAssertEqual(session.model.snips.map(\.content), ["Kept snip"])
        XCTAssertEqual(settings.mode, .localOnly)
        XCTAssertEqual(settings.state, .failed(.iCloudDataReset))
        XCTAssertEqual(settings.statusTitle, "Sync turned off")
        XCTAssertTrue(settings.detail.contains("your library is kept on this device"))
    }

    /// Each stop result and the issue Settings shows for it.
    private static let stopResults: [(result: SnipSnapCloudSyncResult, issue: SyncedContentSyncIssue)] = [
        (.iCloudDataReset, .iCloudDataReset),
        (.iCloudSignedOut, .signInRequired),
        (.iCloudAccountChanged, .iCloudAccountChanged),
    ]

    func testStopTurnsSyncOffAndRecordsOnlyTheStop() async {
        for (result, issue) in Self.stopResults {
            let diagnostics = IOSDiagnosticRecorderProbe()
            let settings = SyncedContentSettingsModel(mode: .iCloudSync, diagnostics: diagnostics.recorder)
            let session = IOSAppSession(
                library: ModelTestLibrary(),
                syncedContentSettings: settings,
                cloudSyncSession: IOSCloudSyncSessionProbe(result: result, activeLibrary: ModelTestLibrary())
            )

            await session.syncWhenPossible()

            XCTAssertEqual(settings.mode, .localOnly, "\(result)")
            XCTAssertEqual(settings.state, .failed(issue), "\(result)")
            XCTAssertEqual(diagnostics.events.map(\.operation), ["sync.stop"], "\(result)")
        }
    }

    func testAutomaticStopResultsReplaceTheLibraryLikeManualSync() async {
        for (result, issue) in Self.stopResults {
            let manualSettings = SyncedContentSettingsModel(mode: .iCloudSync)
            let manual = IOSAppSession(
                library: ModelTestLibrary(snips: [Snip(content: "Cloud copy", origin: .quickEntry)]),
                syncedContentSettings: manualSettings,
                cloudSyncSession: IOSCloudSyncSessionProbe(
                    result: result,
                    activeLibrary: ModelTestLibrary(snips: [Snip(content: "Local copy", origin: .quickEntry)])
                )
            )
            await manual.model.load()
            await manual.syncWhenPossible()

            let automatic = AsyncStream.makeStream(of: SnipSnapCloudSyncResult.self)
            let automaticSettings = SyncedContentSettingsModel(mode: .iCloudSync)
            let lifecycle = IOSAppSession(
                library: ModelTestLibrary(snips: [Snip(content: "Cloud copy", origin: .quickEntry)]),
                syncedContentSettings: automaticSettings,
                cloudSyncSession: IOSCloudSyncSessionProbe(
                    result: .noChange,
                    activeLibrary: ModelTestLibrary(snips: [Snip(content: "Local copy", origin: .quickEntry)]),
                    automaticSyncResults: automatic.stream
                )
            )
            await lifecycle.model.load()
            automatic.continuation.yield(result)
            let stopped = await TestReadiness.wait { automaticSettings.mode == .localOnly }
            XCTAssertTrue(stopped, "\(result)")

            XCTAssertEqual(manual.model.snips.map(\.content), ["Local copy"], "\(result)")
            XCTAssertEqual(lifecycle.model.snips.map(\.content), ["Local copy"], "\(result)")
            XCTAssertEqual(manualSettings.state, .failed(issue), "\(result)")
            XCTAssertEqual(automaticSettings.state, .failed(issue), "\(result)")
        }
    }

    func testFailedCleanupAfterAStopStillTurnsSyncOff() async {
        for (result, issue) in Self.stopResults {
            let diagnostics = IOSDiagnosticRecorderProbe()
            let settings = SyncedContentSettingsModel(mode: .iCloudSync, diagnostics: diagnostics.recorder)
            let session = IOSAppSession(
                library: ModelTestLibrary(),
                syncedContentSettings: settings,
                cloudSyncSession: IOSCloudSyncSessionProbe(
                    result: result,
                    activeLibrary: ModelTestLibrary(),
                    activeLibraryError: .offline
                )
            )

            await session.syncWhenPossible()

            XCTAssertEqual(settings.mode, .localOnly, "\(result)")
            XCTAssertEqual(settings.state, .failed(issue), "\(result)")
            XCTAssertEqual(
                diagnostics.events.map(\.operation),
                ["sync.run", "sync.stop"],
                "\(result)"
            )
        }
    }

    func testFailedCleanupAfterAStopStaysOffOnTheNextSync() async {
        for (result, issue) in Self.stopResults {
            let settings = SyncedContentSettingsModel(mode: .iCloudSync)
            let cloudSession = IOSCloudSyncSessionProbe(
                result: result,
                activeLibrary: ModelTestLibrary(),
                activeLibraryError: .offline
            )
            let session = IOSAppSession(
                library: ModelTestLibrary(),
                syncedContentSettings: settings,
                cloudSyncSession: cloudSession
            )

            await session.syncWhenPossible()
            XCTAssertEqual(settings.mode, .localOnly, "\(result)")
            XCTAssertEqual(settings.state, .failed(issue), "\(result)")

            // The store left iCloud, so a later request finds nothing to sync.
            await cloudSession.setResult(.noChange)
            await session.syncWhenPossible()
            XCTAssertEqual(settings.mode, .localOnly, "\(result)")
            XCTAssertEqual(settings.state, .failed(issue), "\(result)")
        }
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
        let result = await XCTWaiter.fulfillment(of: [updated], timeout: TestReadiness.timeout)

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(session.model.snips.first?.content, "After")
    }

    func testAutomaticFetchKeepsWarningUntilTheSyncEngineSettlesIt() async {
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let fixture = AutomaticSyncFixture(settings: settings)
        settings.recordSyncFailure(.iCloudStorageFull)

        let fetched = await fixture.deliver([.contentUpdated])
        XCTAssertTrue(fetched)
        XCTAssertEqual(settings.state, .failed(.iCloudStorageFull))

        _ = await fixture.deliver([.syncCompleted])
        let settled = await TestReadiness.wait { settings.state == .ready }
        XCTAssertTrue(settled)
    }

    func testScheduledSyncEndsItsTransientStatusAndKeepsEarlierFailures() async {
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let fixture = AutomaticSyncFixture(settings: settings, manualResult: .syncScheduled)

        await fixture.session.syncWhenPossible()

        XCTAssertEqual(settings.state, .ready)

        settings.recordSyncFailure(.retryingSoon)
        let delivered = await fixture.deliver([.syncScheduled])
        XCTAssertTrue(delivered)
        XCTAssertEqual(settings.state, .failed(.retryingSoon))
    }

    func testAutomaticResultsDuringSyncNowKeepItRunning() async {
        let settings = SyncedContentSettingsModel(mode: .iCloudSync)
        let fixture = AutomaticSyncFixture(
            settings: settings,
            manualResult: .syncScheduled,
            pausesCloudWork: true
        )
        let session = fixture.session
        let syncNow = Task { await session.retrySyncWhenPossible() }
        guard await TestReadiness.wait(until: { await fixture.cloudSession.retryCount() == 1 }) else {
            return XCTFail("Sync Now never reached the cloud session")
        }
        XCTAssertEqual(settings.state, .syncing)

        let delivered = await fixture.deliver([.syncScheduled, .contentUpdated])

        XCTAssertTrue(delivered)
        XCTAssertEqual(settings.state, .syncing)
        await fixture.cloudSession.resumeCloudWork()
        await syncNow.value
        XCTAssertEqual(settings.state, .ready)
    }

    func testRoutedComposerSendRejectsSourceDeletedWhileWaitingForMutation() async {
        let work = SnipList(id: UUID(), name: "Work", systemImage: "folder", position: 1)
        let library = ModelTestLibrary(lists: [.inbox, work], suspendsFirstCommand: true)
        let model = makeModel(library: library)
        await model.load()
        let revision = model.libraryRevision
        let delete = Task { await model.deleteList(id: work.id) }
        await library.waitUntilFirstCommandStarts()
        // Runs until it waits for the held mutation, so the send is queued before the mutation resumes.
        let send = Task.immediate {
            await model.createSnip(
                content: "Deleted source draft", in: SnipList.inboxID,
                selectCreatedSnip: false, expectedLibraryRevision: revision,
                expectedSourceListID: work.id
            )
        }
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
        // Runs until it waits for the held mutation, so the send is queued before the mutation resumes.
        let send = Task.immediate {
            await model.createSnip(
                content: source.draft.text, in: SnipList.inboxID,
                selectCreatedSnip: false, expectedLibraryRevision: revision
            )
        }
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
        let original = ModelTestLibrary(lists: lists)
        let replacement = ModelTestLibrary(lists: lists)
        let model = makeModel(library: original)
        await model.load()
        let openingRevision = model.libraryRevision
        await model.replaceLibrary(replacement, recoveryScope: nil)

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
        let originalSnapshot = await original.snapshot(sortedBy: .chronological)
        let replacementSnapshot = await replacement.snapshot(sortedBy: .chronological)
        XCTAssertTrue(originalSnapshot.snips.isEmpty, "Commands after a replacement must not reach the old library")
        XCTAssertEqual(replacementSnapshot.snips.map(\.content), ["Current picker draft"])
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
        _ = await TestReadiness.wait { !draft.isStaging }
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
        _ = await TestReadiness.wait { draft.isSaving }
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

    func testResetReplacementWaitsForAnInFlightEdit() async {
        let localLibrary = ModelTestLibrary(suspendsFirstCommand: true)
        let resetLibrary = ModelTestLibrary()
        let model = IOSAppModel(library: localLibrary)

        let creation = Task {
            await model.createSnip(content: "In flight", in: SnipList.inboxID)
        }
        await localLibrary.waitUntilFirstCommandStarts()
        // Runs until it waits for the in-flight edit, so the replacement is queued before the edit resumes.
        let replacement = Task.immediate {
            await model.replaceLibrary(resetLibrary, recoveryScope: nil)
        }
        await localLibrary.resumeFirstCommand()
        let created = await creation.value
        XCTAssertTrue(created)
        await replacement.value

        XCTAssertTrue(model.snips.isEmpty, "The edit's result must not show after the reset replaced its library")
        let local = await localLibrary.snapshot(sortedBy: .chronological)
        let reset = await resetLibrary.snapshot(sortedBy: .chronological)
        XCTAssertEqual(local.snips.map(\.content), ["In flight"])
        XCTAssertTrue(reset.snips.isEmpty)
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
        // Runs until it waits for the in-flight edit, so the check below sees any overlap.
        let resolution = Task.immediate {
            await model.resolveRecovery(recovered.id, choice: .keepCurrent)
        }
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
        model.closeSnackbar(undo)
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

/// An iOS session whose automatic sync results the test yields.
@MainActor
private struct AutomaticSyncFixture {
    private static let markerContent = "Marker library"

    let session: IOSAppSession
    let cloudSession: IOSCloudSyncSessionProbe
    private let automatic: AsyncStream<SnipSnapCloudSyncResult>.Continuation

    init(
        settings: SyncedContentSettingsModel,
        manualResult: SnipSnapCloudSyncResult = .noChange,
        pausesCloudWork: Bool = false
    ) {
        let automatic = AsyncStream.makeStream(of: SnipSnapCloudSyncResult.self)
        cloudSession = IOSCloudSyncSessionProbe(
            result: manualResult,
            activeLibrary: ModelTestLibrary(
                snips: [Snip(content: Self.markerContent, origin: .quickEntry)]
            ),
            pausesCloudWork: pausesCloudWork,
            automaticSyncResults: automatic.stream
        )
        session = IOSAppSession(
            library: ModelTestLibrary(
                snips: [Snip(content: Self.markerContent, origin: .quickEntry)]
            ),
            syncedContentSettings: settings,
            cloudSyncSession: cloudSession
        )
        self.automatic = automatic.continuation
    }

    /// Yields `results`, then a content update that must leave the Settings state under test
    /// alone. The reloaded snips appearing shows the stream handled every result first.
    func deliver(_ results: [SnipSnapCloudSyncResult]) async -> Bool {
        for result in results + [.contentUpdated] { automatic.yield(result) }
        return await TestReadiness.wait {
            session.model.snips.map(\.content) == [Self.markerContent]
        }
    }
}
