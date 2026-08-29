import Foundation
import Observation
import SnipSnapCore
import SnipSnapPersistence

@MainActor
@Observable
final class IOSAppModel {
    private var library: any SnipLibrary
    private var recoveryScope: SnipRecoveryScope?
    private let cloudSyncHandler: (any OptionalCloudSyncHandling)?

    private(set) var snips: [Snip]
    private(set) var lists: [SnipList]
    private(set) var attachmentURLs: [UUID: URL]
    private(set) var recoverySnapshot: SnipRecoverySnapshot = .empty
    private var preparedAttachmentURLs: [UUID: URL] = [:]
    private(set) var attachmentTransferStates: [UUID: SyncedAttachmentTransferState] = [:]
    private(set) var isCloudSyncActive = false
    private var hasKnownCloudSyncActivity: Bool
    private var hasKnownCloudAttachmentStates = false
    var selectedListID: UUID
    var selectedSnipID: UUID?
    var errorMessage: String?

    init(
        library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope? = nil,
        initialSnapshot: SnipLibrarySnapshot = SnipLibrarySnapshot(
            snips: [],
            lists: [.inbox]
        ),
        startupError: String? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil
    ) {
        self.library = library
        self.recoveryScope = recoveryScope
        self.cloudSyncHandler = cloudSyncHandler
        hasKnownCloudSyncActivity = cloudSyncHandler == nil
        snips = initialSnapshot.snips
        lists = initialSnapshot.lists
        attachmentURLs = initialSnapshot.attachmentURLs
        selectedListID = SnipList.inboxID
        errorMessage = startupError
    }

    var selectedList: SnipList {
        lists.first(where: { $0.id == selectedListID }) ?? .inbox
    }

    var selectedSnip: Snip? {
        guard let selectedSnipID else { return nil }
        return snips.first(where: { $0.id == selectedSnipID })
    }

    var visibleSnips: [Snip] {
        snips.filter { $0.listID == selectedListID }
    }

    var needsAttentionCount: Int { recoverySnapshot.needsAttentionCount }
    var pendingRecoveredSnips: [RecoveredSnip] { recoverySnapshot.pendingSnips }
    var pendingRecoveredLists: [RecoveredListEdit] { recoverySnapshot.pendingLists }

    func currentSnip(for recovery: RecoveredSnip) -> Snip? {
        snips.first { $0.id == recovery.currentSnipID }
    }

    func currentList(for recovery: RecoveredListEdit) -> SnipList? {
        lists.first { $0.id == recovery.currentListID }
    }

    func isRecoveredSnip(_ snipID: UUID) -> Bool {
        recoverySnapshot.pendingSnips.contains { $0.id == snipID }
            || recoverySnapshot.promotedSnips.contains { $0.id == snipID }
    }

    func load() async {
        apply(await library.snapshot(sortedBy: .chronological))
        await loadRecoveries()
        await refreshAttachmentTransferStates()
    }

    func replaceLibrary(
        _ library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope?
    ) async {
        self.library = library
        self.recoveryScope = recoveryScope
        selectedSnipID = nil
        await load()
    }

    @discardableResult
    func resolveRecovery(_ id: UUID, choice: SnipRecoveryChoice) async -> Bool {
        guard let recoveryScope else { return false }
        do {
            apply(try await library.resolveRecovery(id, in: recoveryScope, choice: choice))
            await loadRecoveries()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await load()
            return false
        }
    }

    @discardableResult
    func createSnip(
        content: String,
        in listID: UUID,
        attachmentURLs: [URL] = []
    ) async -> Bool {
        await perform(
            .add(
                content: content,
                origin: .quickEntry,
                source: nil,
                listID: listID,
                attachmentURLs: attachmentURLs,
                requestID: UUID(),
                now: Date()
            )
        ) { outcome in
            if case .add(.added(let id)) = outcome {
                selectedListID = listID
                selectedSnipID = id
            }
        }
    }

    @discardableResult
    func editSnip(
        _ snip: Snip,
        content: String,
        attachmentEdits: [SnipAttachmentEdit]? = nil
    ) async -> Bool {
        if let attachmentEdits {
            await perform(
                .editAttachments(
                    snipID: snip.id,
                    content: content,
                    edits: attachmentEdits,
                    expectedUpdatedAt: snip.updatedAt,
                    now: Date()
                )
            )
        } else {
            await perform(
                .update(
                    id: snip.id,
                    content: content,
                    attachmentURLs: nil,
                    expectedUpdatedAt: snip.updatedAt,
                    now: Date()
                )
            )
        }
    }

    func attachmentURL(for attachmentID: UUID) -> URL? {
        if cloudSyncHandler != nil, !hasKnownCloudSyncActivity {
            return preparedAttachmentURLs[attachmentID]
        }
        if isCloudSyncActive,
           !hasKnownCloudAttachmentStates || attachmentTransferStates[attachmentID] != nil
        {
            return preparedAttachmentURLs[attachmentID]
        }
        return attachmentURLs[attachmentID]
    }

    var hasCloudSync: Bool { isCloudSyncActive }

    func attachmentTransferState(for attachmentID: UUID) -> SyncedAttachmentTransferState {
        if let state = attachmentTransferStates[attachmentID] { return state }
        if cloudSyncHandler != nil, !hasKnownCloudSyncActivity { return .waiting }
        if isCloudSyncActive, !hasKnownCloudAttachmentStates { return .waiting }
        return attachmentURLs[attachmentID] == nil ? .waiting : .available
    }

    func prepareAttachment(_ attachmentID: UUID, for use: SyncedAttachmentUse) async -> URL? {
        guard let cloudSyncHandler else { return attachmentURLs[attachmentID] }
        if hasKnownCloudSyncActivity, !isCloudSyncActive {
            return attachmentURLs[attachmentID]
        }
        if hasKnownCloudSyncActivity,
           hasKnownCloudAttachmentStates,
           attachmentTransferStates[attachmentID] == nil
        {
            return attachmentURLs[attachmentID]
        }
        attachmentTransferStates[attachmentID] = .syncing
        do {
            let url = try await cloudSyncHandler.prepareSyncedAttachment(attachmentID, for: use)
            attachmentURLs[attachmentID] = url
            preparedAttachmentURLs[attachmentID] = url
            attachmentTransferStates[attachmentID] = .available
            return url
        } catch {
            attachmentTransferStates[attachmentID] = .failed
            errorMessage = "Snip Snap could not download that attachment. Please try again."
            return nil
        }
    }

    func clearDownloadedFiles() async {
        guard let cloudSyncHandler else { return }
        do {
            try await cloudSyncHandler.clearDownloadedFiles()
            apply(await library.snapshot(sortedBy: .chronological))
            await refreshAttachmentTransferStates()
        } catch {
            errorMessage = "Snip Snap could not clear the downloaded files."
        }
    }

    func syncWhenPossible() async {
        await cloudSyncHandler?.syncWhenPossible()
        await load()
    }

    @discardableResult
    func deleteSnip(id: UUID) async -> Bool {
        let deleted = await perform(.delete(ids: [id])) { _ in
            if selectedSnipID == id { selectedSnipID = nil }
        }
        guard deleted else { return false }
        _ = await perform(.pruneAttachments(retaining: []))
        return true
    }

    @discardableResult
    func moveSnip(id: UUID, to listID: UUID) async -> Bool {
        await perform(.moveChronologically(ids: [id], to: listID)) { _ in
            selectedListID = listID
            selectedSnipID = id
        }
    }

    @discardableResult
    func createList(name: String) async -> Bool {
        await perform(.createList(name: name, systemImage: "list.bullet")) { outcome in
            if case .listCreated(let list) = outcome {
                selectedListID = list.id
                selectedSnipID = nil
            }
        }
    }

    @discardableResult
    func renameList(_ list: SnipList, name: String) async -> Bool {
        await perform(.updateList(id: list.id, name: name, systemImage: list.systemImage))
    }

    @discardableResult
    func deleteList(id: UUID) async -> Bool {
        await perform(.deleteList(id: id)) { _ in
            selectedListID = SnipList.inboxID
            selectedSnipID = nil
        }
    }

    private func perform(
        _ command: SnipLibraryCommand,
        afterSuccess: (SnipLibraryOutcome) -> Void = { _ in }
    ) async -> Bool {
        do {
            let update = try await library.perform(command, sortedBy: .chronological)
            apply(update.snapshot)
            await loadRecoveries()
            await refreshAttachmentTransferStates()
            afterSuccess(update.outcome)
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func loadRecoveries() async {
        guard let recoveryScope else {
            recoverySnapshot = .empty
            return
        }
        do {
            recoverySnapshot = try await library.recoverySnapshot(in: recoveryScope)
        } catch {
            recoverySnapshot = .empty
        }
    }

    private func apply(_ snapshot: SnipLibrarySnapshot) {
        snips = snapshot.snips
        lists = snapshot.lists
        attachmentURLs = snapshot.attachmentURLs
        preparedAttachmentURLs.removeAll()

        if !lists.contains(where: { $0.id == selectedListID }) {
            selectedListID = SnipList.inboxID
        }
        if let selectedSnipID, !snips.contains(where: { $0.id == selectedSnipID }) {
            self.selectedSnipID = nil
        }
    }

    private func refreshAttachmentTransferStates() async {
        guard let cloudSyncHandler else {
            isCloudSyncActive = false
            hasKnownCloudSyncActivity = true
            hasKnownCloudAttachmentStates = true
            attachmentTransferStates = Dictionary(uniqueKeysWithValues:
                attachmentURLs.keys.map { ($0, .available) }
            )
            return
        }
        hasKnownCloudSyncActivity = false
        do {
            isCloudSyncActive = try await cloudSyncHandler.isCloudSyncActive()
            hasKnownCloudSyncActivity = true
            guard isCloudSyncActive else {
                hasKnownCloudAttachmentStates = true
                attachmentTransferStates = [:]
                preparedAttachmentURLs.removeAll()
                return
            }
            attachmentTransferStates = try await cloudSyncHandler.syncedAttachmentStates()
            hasKnownCloudAttachmentStates = true
            preparedAttachmentURLs = preparedAttachmentURLs.filter {
                attachmentTransferStates[$0.key] != nil
            }
        } catch {
            if isCloudSyncActive { hasKnownCloudAttachmentStates = false }
            // Keep the last known states while iCloud is unavailable.
        }
    }
}

@MainActor
final class IOSAppGraph {
    let model: IOSAppModel
    let shareImporter: IOSShareImportCoordinator?

    init(
        library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope? = nil,
        shareImports: ShareImportStore?,
        initialSnapshot: SnipLibrarySnapshot,
        startupError: String?,
        shareImportOperation: (@Sendable () async -> Int)? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil
    ) {
        let model = IOSAppModel(
            library: library,
            recoveryScope: recoveryScope,
            initialSnapshot: initialSnapshot,
            startupError: startupError,
            cloudSyncHandler: cloudSyncHandler
        )
        self.model = model
        if let shareImportOperation {
            shareImporter = IOSShareImportCoordinator(
                model: model,
                importOperation: shareImportOperation
            )
        } else if let shareImports {
            shareImporter = IOSShareImportCoordinator(
                library: library,
                imports: shareImports,
                model: model
            )
        } else {
            shareImporter = nil
        }
    }
}

@MainActor
final class IOSShareImportCoordinator {
    private let model: IOSAppModel
    private let importOperation: @Sendable () async -> Int
    private var inFlight: Task<Int, Never>?

    convenience init(
        library: any SnipLibrary,
        imports: ShareImportStore,
        model: IOSAppModel
    ) {
        self.init(
            model: model,
            importOperation: {
                await imports.importPending(into: library).failed
            }
        )
    }

    init(
        model: IOSAppModel,
        importOperation: @escaping @Sendable () async -> Int
    ) {
        self.model = model
        self.importOperation = importOperation
    }

    func importPendingAndReload() async {
        if let inFlight {
            _ = await inFlight.value
            return
        }
        let task = Task { [model, importOperation] in
            let failed = await importOperation()
            await model.load()
            if failed > 0 {
                model.errorMessage =
                    "One or more shared items could not be added yet. Snip Snap will try again next time."
            }
            return failed
        }
        inFlight = task
        _ = await task.value
        inFlight = nil
    }
}
