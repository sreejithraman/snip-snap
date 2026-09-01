import Foundation
import SnipSnapCloud
import SnipSnapCore
import SnipSnapPersistence

protocol IOSCloudSyncSessionHandling: Sendable {
    func synchronize() async throws -> SnipSnapCloudSyncResult
    func scheduleAutomaticSync() async
    func iosActiveLibrary() async throws -> (library: any SnipLibrary, recoveryScope: SnipRecoveryScope?)
    var automaticSyncResults: AsyncStream<SnipSnapCloudSyncResult> { get }
}

extension IOSCloudSyncSessionHandling {
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
        shareImportOperation: (@Sendable () async -> Int)? = nil,
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
                if let cloudSyncSession {
                    guard let active = try? await cloudSyncSession.iosActiveLibrary() else {
                        return 1
                    }
                    return await imports.importPending(into: active.library).failed
                }
                return await imports.importPending(into: library).failed
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
            syncedContentSettings.setEncryptedDataResetCompletionAction(reloadActiveLibrary)
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

    func scheduleSyncAfterLocalChange() async {
        await cloudSyncSession?.scheduleAutomaticSync()
    }

    private func handleAutomaticSyncResult(_ result: SnipSnapCloudSyncResult) async {
        switch result {
        case .contentUpdated:
            await model.load()
        case .encryptedDataResetRequiresChoice:
            if let cloudSyncSession,
               let active = try? await cloudSyncSession.iosActiveLibrary()
            {
                await model.replaceLibrary(
                    active.library,
                    recoveryScope: active.recoveryScope
                )
            }
            syncedContentSettings.recordEncryptedDataReset()
        default:
            break
        }
        syncedContentSettings.recordSyncCompleted()
    }

    private static func synchronizeCloudSessionOrThrow(
        _ session: (any IOSCloudSyncSessionHandling)?,
        model: IOSAppModel,
        settings: SyncedContentSettingsModel
    ) async throws {
        guard let session else { return }
        settings.recordSyncStarted()
        do {
            let result = try await session.synchronize()
            switch result {
            case .noChange:
                break
            case .contentUpdated:
                await model.load()
            case .iCloudSyncSettingUp:
                settings.recordEnableSettingUp()
            case .iCloudSyncEnabled:
                let active = try await session.iosActiveLibrary()
                await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                settings.recordEnableCompleted()
            case .libraryReplaced, .oldSyncedContentRemovalPending,
                    .oldSyncedContentRemovalCompleted, .encryptedDataResetRequiresChoice,
                    .syncKeptOff:
                let active = try await session.iosActiveLibrary()
                await model.replaceLibrary(active.library, recoveryScope: active.recoveryScope)
                if case .oldSyncedContentRemovalPending = result {
                    settings.recordRemovalPending(true)
                } else if case .oldSyncedContentRemovalCompleted = result {
                    settings.recordRemovalPending(false)
                } else if case .encryptedDataResetRequiresChoice = result {
                    settings.recordEncryptedDataReset()
                }
            }
            settings.recordSyncCompleted()
        } catch {
            settings.recordSyncFailure(error.localizedDescription)
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

    func scheduleSyncAfterLocalChange() async {
        await session?.scheduleSyncAfterLocalChange()
    }
}

@MainActor
final class IOSShareImportCoordinator {
    private struct PassResult: Sendable {
        let importFailures: Int
        let syncFailed: Bool
    }

    private let model: IOSAppModel
    private let importOperation: @Sendable () async -> Int
    private let syncOperation: @MainActor @Sendable () async throws -> Void
    private var inFlight: Task<PassResult, Never>?
    private var needsTrailingPass = false

    init(
        model: IOSAppModel,
        importOperation: @escaping @Sendable () async -> Int,
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
            var syncFailed = false
            repeat {
                needsTrailingPass = false
                let result = await runPass()
                importFailures += result.importFailures
                syncFailed = syncFailed || result.syncFailed
            } while needsTrailingPass
            inFlight = nil
            return PassResult(importFailures: importFailures, syncFailed: syncFailed)
        }
        inFlight = task
        report(await task.value)
    }

    private func runPass() async -> PassResult {
        let failed = await importOperation()
        await model.load()
        do {
            try await syncOperation()
            return PassResult(importFailures: failed, syncFailed: false)
        } catch {
            return PassResult(importFailures: failed, syncFailed: true)
        }
    }

    private func report(_ result: PassResult) {
        if result.importFailures > 0 {
            model.errorMessage = String(
                localized: "Some shared content could not be added yet. Snip Snap will try again next time."
            )
        } else if result.syncFailed {
            model.errorMessage = String(
                localized: "The shared content is saved on this device. iCloud sync will try again later."
            )
        }
    }
}
