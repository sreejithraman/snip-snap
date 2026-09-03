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

struct IOSLibraryStartup {
    let library: any SnipLibrary
    let sourceLibrary: any SnipLibrary
    let userActions: any SnipLibraryUserActions
    let userActionsRebinder: SnipLibraryUserActionsRebinder
    let shareImports: ShareImportStore?
    let error: String?
    let uiTestAttachmentURLs: [URL]
    let seedsCopyShareFixtures: Bool
    let recoveryScope: SnipRecoveryScope?
    let syncModeStore: SnipSyncModeStore?
    let syncModeRootURL: URL
}

@MainActor
final class IOSAppSession {
    let model: IOSAppModel
    let syncedContentSettings: SyncedContentSettingsModel
    let accountNoticeModel: AppleAccountNoticeModel?

    private let shareImporter: IOSShareImportCoordinator?
    private let cloudLifecycleHooks: SnipSnapCloudLifecycleHooks
    private let cloudSyncSession: (any IOSCloudSyncSessionHandling)?
    private var automaticSyncTask: Task<Void, Never>?

    init(
        library: any SnipLibrary,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsRebinder: SnipLibraryUserActionsRebinder = .direct,
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
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil
    ) {
        let model = IOSAppModel(
            library: library,
            userActions: userActions,
            userActionsRebinder: userActionsRebinder,
            recoveryScope: recoveryScope,
            initialSnapshot: initialSnapshot,
            startupError: startupError,
            cloudSyncHandler: cloudSyncHandler
        )
        self.model = model
        self.syncedContentSettings = syncedContentSettings
        self.accountNoticeModel = accountNoticeModel
        self.cloudSyncSession = cloudSyncSession

        let activeShareImportOperation = shareImportOperation ?? shareImports.map { imports in
            { @Sendable in
                guard await imports.pendingImportCount() > 0 else {
                    return ShareImportSummary(imported: 0, failed: 0)
                }
                if let cloudSyncSession {
                    guard let active = try? await cloudSyncSession.iosActiveLibrary() else {
                        return ShareImportSummary(imported: 0, failed: 1)
                    }
                    return await imports.importPending(into: active.library)
                }
                return await imports.importPending(into: library)
            }
        }
        let syncOperation: @MainActor @Sendable () async throws -> Void = {
            try await Self.synchronizeCloudSessionOrThrow(
                cloudSyncSession,
                model: model,
                settings: syncedContentSettings
            )
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
                let active = try await cloudSyncSession.iosActiveLibrary()
                await model.replaceLibrary(
                    active.library,
                    recoveryScope: active.recoveryScope
                )
            }
            syncedContentSettings.setEnableCompletionAction(reloadActiveLibrary)
            syncedContentSettings.setDisableCompletionAction(reloadActiveLibrary)
            syncedContentSettings.setDeleteCompletionAction(reloadActiveLibrary)
        }
        cloudLifecycleHooks = SnipSnapCloudLifecycleHooks {
            try? await Self.synchronizeCloudSessionOrThrow(
                cloudSyncSession,
                model: model,
                settings: syncedContentSettings
            )
        }
        accountNoticeModel?.setActiveLibraryChangeAction {
            guard let cloudSyncSession else { return }
            let active = try await cloudSyncSession.iosActiveLibrary()
            await model.replaceLibrary(
                active.library,
                recoveryScope: active.recoveryScope
            )
        }
        if let cloudSyncSession {
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
        await cloudLifecycleHooks.launch()
        if let shareImporter {
            await shareImporter.importPendingAndReload()
        } else {
            await model.load()
        }
        await accountNoticeModel?.refresh()
    }

    func foreground() async {
        await cloudLifecycleHooks.foreground()
        await shareImporter?.importPendingAndReload()
        await accountNoticeModel?.refresh()
    }

    func syncWhenPossible() async {
        try? await Self.synchronizeCloudSessionOrThrow(
            cloudSyncSession,
            model: model,
            settings: syncedContentSettings
        )
    }

    func retrySyncWhenPossible() async {
        try? await Self.synchronizeCloudSessionOrThrow(
            cloudSyncSession,
            model: model,
            settings: syncedContentSettings,
            retryingUserRecoverableFailures: true
        )
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
        case .iCloudDataReset, .iCloudSignedOut, .iCloudAccountChanged:
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
        retryingUserRecoverableFailures: Bool = false
    ) async throws {
        guard let session else { return }
        settings.recordSyncStarted()
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
                settings.recordOutstandingSyncRecovered()
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
                    settings.recordRemovalPending(true)
                } else if case .oldSyncedContentRemovalCompleted = result {
                    settings.recordRemovalPending(false)
                }
            case .iCloudDataReset, .iCloudSignedOut, .iCloudAccountChanged:
                let active = try await session.iosActiveLibrary()
                await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                let issue: SyncedContentSyncIssue
                switch result {
                case .iCloudDataReset:
                    issue = .iCloudDataReset
                case .iCloudSignedOut:
                    issue = .signInRequired
                default:
                    issue = .iCloudAccountChanged
                }
                settings.recordSyncStopped(issue)
            case .syncIssue(let issue):
                settings.recordSyncFailure(issue)
                return
            }
            settings.recordSyncCompleted()
        } catch {
            settings.recordSyncFailure(SnipSnapCloudSyncIssueMapper.issue(for: error))
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

    func scheduleSyncAfterLocalChange() async {
        await session?.scheduleSyncAfterLocalChange()
    }
}

@MainActor
final class IOSShareImportCoordinator {
    private let model: IOSAppModel
    private let importOperation: @Sendable () async -> ShareImportSummary
    private let syncOperation: @MainActor @Sendable () async throws -> Void
    private var inFlight: Task<Int, Never>?
    private var needsTrailingPass = false

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
        if let inFlight {
            needsTrailingPass = true
            _ = await inFlight.value
            return
        }
        let task = Task { [self] in
            var importFailures = 0
            repeat {
                needsTrailingPass = false
                importFailures += await runPass()
            } while needsTrailingPass
            inFlight = nil
            return importFailures
        }
        inFlight = task
        report(await task.value)
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
            model.errorMessage = String(
                localized: "Some shared content could not be added yet. Snip Snap will try again next time."
            )
        }
    }
}
