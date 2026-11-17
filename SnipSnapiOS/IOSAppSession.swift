import Foundation
import SnipSnapCloud
import SnipSnapCore
import SnipSnapPersistence

protocol IOSCloudSyncSessionHandling: Sendable {
    func synchronize() async throws -> SnipSnapCloudSyncResult
    func retrySynchronization() async throws -> SnipSnapCloudSyncResult
    func scheduleAutomaticSync() async
    func iosActiveLibrary() async throws -> (library: any SnipLibrary, recoveryScope: SnipRecoveryScope?)
    var automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult> { get }
}

extension IOSCloudSyncSessionHandling {
    func retrySynchronization() async throws -> SnipSnapCloudSyncResult {
        try await synchronize()
    }

    func scheduleAutomaticSync() async {}

    var automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult> {
        AsyncStream { $0.finish() }
    }
}

extension SnipSnapCloudSyncSession: IOSCloudSyncSessionHandling {
    func iosActiveLibrary() async throws
        -> (library: any SnipLibrary, recoveryScope: SnipRecoveryScope?)
    {
        let active = try await activeLibrary()
        return (active.library, active.recoveryScope)
    }
}

protocol IOSCloudSyncOutcomeSessionHandling: IOSCloudSyncSessionHandling {
    func synchronizeWithTarget() async throws -> SnipSnapCloudSyncDelivery
    func retrySynchronizationWithTarget() async throws -> SnipSnapCloudSyncDelivery
    func currentApplicationTarget() async throws -> SnipSnapCloudApplicationTarget?
    var automaticSyncDeliveries: AsyncStream<SnipSnapCloudSyncDelivery> { get }
}

extension SnipSnapCloudSyncSession: IOSCloudSyncOutcomeSessionHandling {}

struct IOSLibraryStartup {
    let library: any SnipLibrary
    let sourceLibrary: any SnipLibrary
    let userActions: any SnipLibraryUserActions
    let userActionsFactory: SnipLibraryUserActionsFactory
    let shareImports: ShareImportStore?
    let error: String?
    let uiTestAttachmentURLs: [URL]
    let seedsCopyShareFixtures: Bool
    let recoveryScope: SnipRecoveryScope?
    let syncModeStore: SnipSyncModeStore?
    let syncModeRootURL: URL
    let clipboardRootURL: URL
    let attachmentCacheRootURL: URL?
}

@MainActor
final class IOSAppSession {
    let model: IOSAppModel
    let clipboard: IOSClipboardModel
    let syncedContentSettings: SyncedContentSettingsModel
    let accountNoticeModel: AppleAccountNoticeModel?

    private let shareImporter: IOSShareImportCoordinator?
    private let shareDestinationPublisher: ShareListCatalogPublisher?
    private let cloudLifecycleHooks: SnipSnapCloudLifecycleHooks
    private let cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private let cloudSyncSession: (any IOSCloudSyncSessionHandling)?
    private var automaticSyncTask: Task<Void, Never>?

    init(
        library: any SnipLibrary,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsFactory: @escaping SnipLibraryUserActionsFactory = { DirectSnipLibraryUserActions(library: $0) },
        recoveryScope: SnipRecoveryScope? = nil,
        shareImports: ShareImportStore? = nil,
        initialSnapshot: SnipLibrarySnapshot = SnipLibrarySnapshot(
            snips: [],
            lists: [.inbox]
        ),
        startupError: String? = nil,
        syncedContentSettings: SyncedContentSettingsModel = SyncedContentSettingsModel(
            mode: .localOnly
        ),
        cloudSyncSession: (any IOSCloudSyncSessionHandling)? = nil,
        shareImportOperation: (@Sendable () async -> ShareImportSummary)? = nil,
        accountNoticeModel: AppleAccountNoticeModel? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil,
        haptics: IOSHapticFeedback = IOSHapticFeedback(),
        clipboardRootURL: URL? = nil,
        clipboardSyncRootURL: URL? = nil,
        clipboardContainerIdentifier: String? = nil,
        diagnostics: AppDiagnosticRecorder = .live
    ) {
        let shareDestinationPublisher = shareImports.map {
            ShareListCatalogPublisher(imports: $0)
        }
        let model = IOSAppModel(
            library: library,
            userActions: userActions,
            userActionsFactory: userActionsFactory,
            recoveryScope: recoveryScope,
            initialSnapshot: initialSnapshot,
            startupError: startupError,
            cloudSyncHandler: cloudSyncHandler,
            haptics: haptics,
            diagnostics: diagnostics,
            publishShareDestinations: shareDestinationPublisher.map { publisher in
                { lists in
                    publisher.enqueue(lists)
                }
            }
        )
        self.model = model
        self.shareDestinationPublisher = shareDestinationPublisher
        let clipboard = IOSClipboardModel(
            rootURL: clipboardRootURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-Preview-" + UUID().uuidString),
            syncRootURL: clipboardSyncRootURL,
            settings: syncedContentSettings,
            containerIdentifier: clipboardContainerIdentifier,
            generation: {
                guard let cloudSyncSession else { return nil }
                return try await cloudSyncSession.iosActiveLibrary().recoveryScope?.rawValue
            },
            diagnostics: diagnostics
        )
        self.clipboard = clipboard
        self.syncedContentSettings = syncedContentSettings
        self.accountNoticeModel = accountNoticeModel
        self.cloudSyncSession = cloudSyncSession
        self.cloudSyncHandler = cloudSyncHandler
        model.setCheckedCatalogPublisher(shareDestinationPublisher)

        let activeShareImportOperation = shareImportOperation ?? shareImports.map { imports in
            { @Sendable in
                guard await imports.pendingImportCount() > 0 else {
                    return ShareImportSummary(imported: 0, failed: 0)
                }
                if let cloudSyncSession {
                    do {
                        let active = try await cloudSyncSession.iosActiveLibrary()
                        return await imports.importPending(into: active.library)
                    } catch {
                        diagnostics.record(.failure(
                            operation: "share.import_library", error: error, visibility: .background))
                        return ShareImportSummary(imported: 0, failed: 1)
                    }
                }
                return await imports.importPending(into: library)
            }
        }
        let syncOperation: @MainActor @Sendable () async throws -> Void = {
            if let actual = cloudSyncSession as? any IOSCloudSyncOutcomeSessionHandling {
                _ = try await Self.synchronizeChecked(actual, model: model, settings: syncedContentSettings,
                    clipboard: clipboard, handler: cloudSyncHandler, retry: false,
                    start: syncedContentSettings.recordSyncStarted())
            } else {
                try await Self.synchronizeCloudSessionOrThrow(cloudSyncSession, model: model,
                    settings: syncedContentSettings, clipboard: clipboard)
            }
        }
        if let activeShareImportOperation {
            shareImporter = IOSShareImportCoordinator(
                model: model,
                importOperation: activeShareImportOperation,
                syncOperation: syncOperation
            )
        } else {
            shareImporter = nil
        }

        if let cloudSyncSession {
            let reloadActiveLibrary: SyncedContentSettingsModel.DeleteCompletionAction = {
                if let actual = cloudSyncSession as? any IOSCloudSyncOutcomeSessionHandling {
                    guard let target = try await actual.currentApplicationTarget() else { throw SnipLibraryReadPublicationError.revoked }
                    _ = try await model.applyChecked(target.application)
                } else {
                    let active = try await cloudSyncSession.iosActiveLibrary()
                    await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                }
            }
            syncedContentSettings.setEnableCompletionAction(reloadActiveLibrary)
            syncedContentSettings.setDisableCompletionAction(reloadActiveLibrary)
            syncedContentSettings.setDeleteCompletionAction(reloadActiveLibrary)
        }
        if cloudSyncSession is any IOSCloudSyncOutcomeSessionHandling {
            syncedContentSettings.setCheckedEnableCompletionAction { [weak model, weak clipboard, weak settings = syncedContentSettings] target, start in
                guard let model, let clipboard, let settings else { throw SnipLibraryReadPublicationError.revoked }
                _ = try await model.applyChecked(target, completion: IOSAppModel.SyncApplicationCompletion(
                    settings: settings, clipboard: clipboard, start: start, enabling: true))
                settings.endSyncAction(start)
                await Self.confirmCurrent(target.source, model: model, settings: settings, handler: cloudSyncHandler, start: start)
            }
        }
        cloudLifecycleHooks = SnipSnapCloudLifecycleHooks {
            await cloudSyncSession?.scheduleAutomaticSync()
        }
        accountNoticeModel?.setActiveLibraryChangeAction {
            guard let cloudSyncSession else { return }
            if let actual = cloudSyncSession as? any IOSCloudSyncOutcomeSessionHandling {
                guard let target = try await actual.currentApplicationTarget() else { throw SnipLibraryReadPublicationError.revoked }
                _ = try await model.applyChecked(target.application)
            } else {
                let active = try await cloudSyncSession.iosActiveLibrary()
                await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
            }
        }
        if let actual = cloudSyncSession as? any IOSCloudSyncOutcomeSessionHandling {
            let results = actual.automaticSyncDeliveries
            automaticSyncTask = Task { [weak self] in
                for await delivery in results {
                    guard let self, !Task.isCancelled else { return }
                    let start = self.syncedContentSettings.recordSyncStarted()
                    _ = await Self.applyDelivery(delivery, model: self.model, settings: self.syncedContentSettings,
                        clipboard: self.clipboard, handler: self.cloudSyncHandler, start: start)
                }
            }
        } else if let cloudSyncSession {
            let results = cloudSyncSession.automaticSyncResults
            automaticSyncTask = Task { [weak self] in
                for await result in results {
                    guard let self, !Task.isCancelled else { return }
                    await self.handleAutomaticSyncResult(result)
                }
            }
        }
    }

    func launch() async {
        if let actual = cloudSyncSession as? any IOSCloudSyncOutcomeSessionHandling {
            do {
                if let target = try await actual.currentApplicationTarget() {
                    _ = try await model.applyChecked(target.application)
                } else if model.appliedSource == nil {
                    await model.load()
                } else { throw SnipLibraryReadPublicationError.revoked }
            } catch { model.presentError(error, operation: "sync.snapshot") }
        } else { await model.load() }
        model.publishCurrentCatalog(force: true)
        await cloudLifecycleHooks.run()
        await clipboard.foreground()
        if let shareImporter {
            await shareImporter.importPendingAndReload()
        }
        await accountNoticeModel?.refresh()
    }

    func foreground() async {
        model.publishCurrentCatalog(force: true)
        await cloudLifecycleHooks.run()
        await clipboard.foreground()
        await shareImporter?.importPendingAndReload()
        await accountNoticeModel?.refresh()
    }

    func syncWhenPossible() async {
        if let actual = cloudSyncSession as? any IOSCloudSyncOutcomeSessionHandling {
            _ = try? await Self.synchronizeChecked(actual, model: model, settings: syncedContentSettings,
                clipboard: clipboard, handler: cloudSyncHandler, retry: false,
                start: syncedContentSettings.recordSyncStarted())
            await clipboard.synchronize()
            return
        }
        try? await Self.synchronizeCloudSessionOrThrow(
            cloudSyncSession,
            model: model,
            settings: syncedContentSettings,
            clipboard: clipboard
        )
        await clipboard.synchronize()
    }

    func retrySyncWhenPossible() async {
        if cloudSyncSession is any IOSCloudSyncOutcomeSessionHandling {
            _ = try? await retrySyncWithOutcome()
            return
        }
        model.haptics.invalidatePendingFeedback()
        await syncedContentSettings.performExplicitSync {
            try? await Self.synchronizeCloudSessionOrThrow(
                cloudSyncSession,
                model: model,
                settings: syncedContentSettings,
                clipboard: clipboard,
                retryingUserRecoverableFailures: true
            )
            await clipboard.synchronize()
        }
    }

    func retrySyncWithOutcome() async throws -> SyncedContentActionOutcome {
        guard let actual = cloudSyncSession as? any IOSCloudSyncOutcomeSessionHandling else {
            return .notRun(.unavailableSession)
        }
        model.haptics.invalidatePendingFeedback()
        return try await syncedContentSettings.performExplicitSyncWithOutcome { start in
            do {
                let original = try await Self.synchronizeChecked(actual, model: model, settings: syncedContentSettings,
                    clipboard: clipboard, handler: cloudSyncHandler, retry: true, start: start)
                await clipboard.synchronize()
                return original
            } catch {
                await clipboard.synchronize()
                throw error
            }
        }
    }

    private static func synchronizeChecked(
        _ session: any IOSCloudSyncOutcomeSessionHandling, model: IOSAppModel,
        settings: SyncedContentSettingsModel, clipboard: IOSClipboardModel,
        handler: (any OptionalCloudSyncHandling)?, retry: Bool, start: SyncedContentSyncStart
    ) async throws -> SyncedContentOriginalActionReturn {
        do {
            let delivery = try await (retry ? session.retrySynchronizationWithTarget() : session.synchronizeWithTarget())
            try Task.checkCancellation()
            return await applyDelivery(delivery, model: model, settings: settings,
                clipboard: clipboard, handler: handler, start: start)
        } catch {
            if !(error is CancellationError) { settings.recordSyncFailure(SnipSnapCloudSyncIssueMapper.issue(for: error), for: start) }
            settings.endSyncAction(start)
            throw error
        }
    }

    private static func applyDelivery(
        _ delivery: SnipSnapCloudSyncDelivery, model: IOSAppModel,
        settings: SyncedContentSettingsModel, clipboard: IOSClipboardModel,
        handler: (any OptionalCloudSyncHandling)?, start: SyncedContentSyncStart
    ) async -> SyncedContentOriginalActionReturn {
        defer { settings.endSyncAction(start) }
        let original = delivery.result.originalActionValue
        if delivery.result.requiresApplication {
            guard let target = delivery.target else {
                return .finished(original, .unavailable(.sourceUnavailable))
            }
            do {
                let completion = IOSAppModel.SyncApplicationCompletion(settings: settings, clipboard: clipboard,
                    start: start, stoppedIssue: original.stopIssue, enabling: delivery.result == .iCloudSyncEnabled,
                    removalCompleted: delivery.result.removalCompleted)
                _ = try await model.applyChecked(target.application, completion: completion)
            } catch { return .finished(original, .failed(error)) }
        }
        if case .iCloudSyncSettingUp(let issue) = delivery.result { settings.recordEnableSettingUp(issue, for: start) }
        settings.endSyncAction(start)
        if delivery.result.offersCurrentConfirmation, let target = delivery.target {
            await confirmCurrent(target.application.source, model: model, settings: settings, handler: handler, start: start)
        }
        return .finished(original, delivery.result.requiresApplication ? .applied : .notRequired)
    }

    private static func confirmCurrent(
        _ source: SnipLibraryReadSource, model: IOSAppModel, settings: SyncedContentSettingsModel,
        handler: (any OptionalCloudSyncHandling)?, start: SyncedContentSyncStart
    ) async {
        guard let handler, model.appliedSource == source else { return }
        do {
            let current = try await handler.checkedCurrentSyncStatus(for: source)
            _ = try model.installCurrentSyncStatus(current, settings: settings, start: start)
        } catch { /* Optional confirmation cannot replace the original operation or its required application. */ }
    }

    func scheduleSyncAfterLocalChange() async {
        await cloudSyncSession?.scheduleAutomaticSync()
    }

    private func handleAutomaticSyncResult(_ result: SnipSnapCloudSyncResult) async {
        switch result {
        case .contentUpdated:
            await model.load()
        case .syncCompleted:
            await model.load()
            syncedContentSettings.recordOutstandingSyncRecovered()
        case .syncScheduled:
            break
        case .libraryReplacedWithSyncIssue(let issue):
            if let cloudSyncSession,
               let active = try? await cloudSyncSession.iosActiveLibrary()
            {
                await model.replaceLibrary(
                    active.library,
                    recoveryScope: active.recoveryScope
                )
            }
            syncedContentSettings.recordSyncFailure(issue)
        case .libraryReplacedAndSyncCompleted:
            if let cloudSyncSession,
               let active = try? await cloudSyncSession.iosActiveLibrary()
            {
                await model.replaceLibrary(
                    active.library,
                    recoveryScope: active.recoveryScope
                )
            }
            syncedContentSettings.recordOutstandingSyncRecovered()
        case .libraryReplacedAndSyncScheduled:
            if let cloudSyncSession,
               let active = try? await cloudSyncSession.iosActiveLibrary()
            {
                await model.replaceLibrary(
                    active.library,
                    recoveryScope: active.recoveryScope
                )
            }
        case .iCloudDataReset, .iCloudSignedOut, .iCloudAccountChanged:
            clipboard.stop()
            await clipboard.resetAccountBinding()
            if let cloudSyncSession,
               let active = try? await cloudSyncSession.iosActiveLibrary()
            {
                await model.replaceLibrary(
                    active.library,
                    recoveryScope: active.recoveryScope
                )
            }
            let issue: SyncedContentSyncIssue
            switch result {
            case .iCloudDataReset:
                issue = .iCloudDataReset
            case .iCloudSignedOut:
                issue = .signInRequired
            default:
                issue = .iCloudAccountChanged
            }
            syncedContentSettings.recordSyncStopped(issue)
        case .syncIssue(let issue):
            syncedContentSettings.recordSyncFailure(issue)
            return
        default:
            break
        }
    }

    private static func synchronizeCloudSessionOrThrow(
        _ session: (any IOSCloudSyncSessionHandling)?,
        model: IOSAppModel,
        settings: SyncedContentSettingsModel,
        clipboard: IOSClipboardModel,
        retryingUserRecoverableFailures: Bool = false
    ) async throws {
        guard let session else { return }
        let syncStart = settings.recordSyncStarted()
        var stopIssue: SyncedContentSyncIssue?
        do {
            let result: SnipSnapCloudSyncResult
            if retryingUserRecoverableFailures {
                result = try await session.retrySynchronization()
            } else {
                result = try await session.synchronize()
            }
            switch result {
            case .noChange:
                break
            case .contentUpdated:
                await model.load()
            case .syncCompleted:
                await model.load()
                settings.recordOutstandingSyncRecovered()
            case .syncScheduled:
                break
            case .iCloudSyncSettingUp(let issue):
                settings.recordEnableSettingUp(issue)
            case .iCloudSyncEnabled:
                let active = try await session.iosActiveLibrary()
                await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                settings.recordEnableCompleted()
            case .libraryReplaced, .oldSyncedContentRemovalPending,
                    .oldSyncedContentRemovalCompleted:
                let active = try await session.iosActiveLibrary()
                await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                if case .oldSyncedContentRemovalPending = result {
                    settings.recordRemovalPending()
                } else if case .oldSyncedContentRemovalCompleted = result {
                    settings.recordRemovalCompleted(syncStart)
                }
            case .libraryReplacedWithSyncIssue(let issue):
                let active = try await session.iosActiveLibrary()
                await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                settings.recordSyncFailure(issue)
                return
            case .libraryReplacedAndSyncCompleted:
                let active = try await session.iosActiveLibrary()
                await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                settings.recordOutstandingSyncRecovered()
            case .libraryReplacedAndSyncScheduled:
                let active = try await session.iosActiveLibrary()
                await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                break
            case .iCloudDataReset, .iCloudSignedOut, .iCloudAccountChanged:
                let issue: SyncedContentSyncIssue
                switch result {
                case .iCloudDataReset:
                    issue = .iCloudDataReset
                case .iCloudSignedOut:
                    issue = .signInRequired
                default:
                    issue = .iCloudAccountChanged
                }
                stopIssue = issue
                clipboard.stop()
                await clipboard.resetAccountBinding()
                let active = try await session.iosActiveLibrary()
                await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                settings.recordSyncStopped(issue)
            case .syncIssue(let issue):
                settings.recordSyncFailure(issue)
                return
            }
            if result != .oldSyncedContentRemovalPending {
                settings.recordSyncCompleted(syncStart)
            }
        } catch {
            settings.recordSyncFailure(SnipSnapCloudSyncIssueMapper.issue(for: error))
            if let stopIssue { settings.recordSyncStopped(stopIssue) }
            throw error
        }
    }
}

@MainActor
final class IOSCloudSyncActionBridge {
    weak var session: IOSAppSession?

    func syncWhenPossible() async {
        await session?.syncWhenPossible()
    }

    func retrySyncWhenPossible() async {
        await session?.retrySyncWhenPossible()
    }

    func retrySyncWithOutcome() async throws -> SyncedContentActionOutcome {
        guard let session else { return .notRun(.unavailableSession) }
        return try await session.retrySyncWithOutcome()
    }

    func scheduleSyncAfterLocalChange() async {
        await session?.scheduleSyncAfterLocalChange()
    }
}

@MainActor
final class IOSShareImportCoordinator {
    private enum ImportPhase {
        case idle
        case importing(Task<Void, Never>, run: UUID, trailingPassQueued: Bool)
    }

    private let model: IOSAppModel
    private let importOperation: @Sendable () async -> ShareImportSummary
    private let syncOperation: @MainActor @Sendable () async throws -> Void
    private var phase = ImportPhase.idle

    init(
        model: IOSAppModel,
        importOperation: @escaping @Sendable () async -> ShareImportSummary,
        syncOperation: @escaping @MainActor @Sendable () async throws -> Void = {}
    ) {
        self.model = model
        self.importOperation = importOperation
        self.syncOperation = syncOperation
    }

    func importPendingAndReload() async {
        if case .importing(let task, let run, _) = phase {
            phase = .importing(task, run: run, trailingPassQueued: true)
            await task.value
            return
        }
        let run = UUID()
        let task = Task { [self] in
            var importFailures = 0
            repeat {
                startPass(of: run)
                importFailures = await runPass()
            } while hasQueuedTrailingPass(in: run)
            finishImport(run)
            report(importFailures)
        }
        phase = .importing(task, run: run, trailingPassQueued: false)
        await task.value
    }

    /// Clearing the queued pass when a pass starts, not when one ends, lets a trigger that
    /// arrives before the first pass runs join that pass.
    private func startPass(of run: UUID) {
        guard case .importing(let task, run, trailingPassQueued: true) = phase else { return }
        phase = .importing(task, run: run, trailingPassQueued: false)
    }

    private func hasQueuedTrailingPass(in run: UUID) -> Bool {
        if case .importing(_, run, trailingPassQueued: true) = phase { return true }
        return false
    }

    private func finishImport(_ run: UUID) {
        guard case .importing(_, run, _) = phase else { return }
        phase = .idle
    }

    private func runPass() async -> Int {
        let summary = await importOperation()
        await model.load()
        if summary.imported > 0 {
            try? await syncOperation()
        }
        return summary.failed
    }

    private func report(_ importFailures: Int) {
        if importFailures > 0 {
            model.presentError(
                String(localized: "Some shared items couldn’t be added. Snip Snap will try again when you reopen the app."),
                operation: "share.import",
                diagnosticCode: "import.partialFailure"
            )
        }
    }
}
