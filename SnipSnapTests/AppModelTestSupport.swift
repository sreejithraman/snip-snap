import Foundation
import SnipSnapCore
@testable import SnipSnap
@testable import SnipSnapPersistence

actor InMemorySnipLibrary: SnipLibrary {
    private var snips: [Snip]
    private var lists: [SnipList]
    private var attachmentURLs: [UUID: URL]
    private var recovery: SnipRecoverySnapshot
    private(set) var addedContents: [String] = []
    private(set) var snapshotCallCount = 0
    private(set) var recoveryChoices: [SnipRecoveryChoice] = []
    private var suspendsFirstCommand: Bool
    private var failsAfterNextWrite = false
    private var failsBeforeNextWrite = false
    private var failsRecoveryReadAfterNextWrite = false
    private var failsNextCheckedSnapshot = false
    private var recoveryOnCheckedFailure: SnipRecoverySnapshot?
    private var returnsFallbackSnapshot = false
    private var firstCommandStarted = false
    private var firstCommandStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCommandContinuation: CheckedContinuation<Void, Never>?

    init(
        snips: [Snip],
        lists: [SnipList] = [.inbox],
        recovery: SnipRecoverySnapshot = .empty,
        attachmentURLs: [UUID: URL] = [:],
        suspendsFirstCommand: Bool = false
    ) {
        self.snips = snips
        self.lists = lists
        self.recovery = recovery
        self.attachmentURLs = attachmentURLs
        self.suspendsFirstCommand = suspendsFirstCommand
    }

    func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        snapshotCallCount += 1
        if returnsFallbackSnapshot {
            returnsFallbackSnapshot = false
            return SnipLibrarySnapshot(snips: [], lists: [.inbox])
        }
        return makeSnapshot(sortedBy: sortMode)
    }

    func checkedSnapshot(sortedBy sortMode: SnipSortMode) throws -> SnipLibrarySnapshot {
        if failsNextCheckedSnapshot {
            failsNextCheckedSnapshot = false
            if let recoveryOnCheckedFailure {
                recovery = recoveryOnCheckedFailure
                self.recoveryOnCheckedFailure = nil
            }
            throw SnipLibraryError.storeUnavailable
        }
        return makeSnapshot(sortedBy: sortMode)
    }

    private func makeSnapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        SnipLibrarySnapshot(
            snips: Snip.sorted(snips, by: sortMode),
            lists: lists,
            attachmentURLs: attachmentURLs.filter {
                FileManager.default.fileExists(atPath: $0.value.path)
            }
        )
    }

    func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate {
        if suspendsFirstCommand {
            suspendsFirstCommand = false
            firstCommandStarted = true
            firstCommandStartWaiters.forEach { $0.resume() }
            firstCommandStartWaiters.removeAll()
            await withCheckedContinuation { firstCommandContinuation = $0 }
        }
        if failsBeforeNextWrite {
            failsBeforeNextWrite = false
            failsNextCheckedSnapshot = true
            throw CocoaError(.fileWriteUnknown)
        }
        let outcome: SnipLibraryOutcome
        switch command {
        case .guarded(_, let inner):
            return try await perform(inner, sortedBy: sortMode)
        case let .add(content, origin, source, listID, _, requestID, now):
            if snips.contains(where: { $0.requestID == requestID }) {
                outcome = .add(.duplicate)
            } else {
                let snip = Snip(
                    requestID: requestID,
                    createdAt: now,
                    content: origin == .selection ? content
                        : content.trimmingCharacters(in: .whitespacesAndNewlines),
                    origin: origin,
                    source: source,
                    listID: listID
                )
                snips.append(snip)
                addedContents.append(content)
                outcome = .add(.added(snip.id))
            }
        case .update(let id, let content, _, _, let now):
            guard let index = snips.firstIndex(where: { $0.id == id }) else {
                throw SnipLibraryError.snipNotFound
            }
            snips[index].content = content
            snips[index].updatedAt = now
            outcome = .none
        case .setDone(let ids, let done):
            for index in snips.indices where ids.contains(snips[index].id) {
                snips[index].isDone = done
            }
            outcome = .none
        case .createList(let name, let systemImage, let color, _):
            let list = SnipList(
                id: UUID(), name: name, systemImage: systemImage,
                color: color, position: lists.count
            )
            lists.append(list)
            outcome = .listCreated(list)
        case .updateList(let id, let name, let systemImage, _):
            guard let index = lists.firstIndex(where: { $0.id == id }) else {
                throw SnipLibraryError.storeUnavailable
            }
            lists[index].name = name
            lists[index].systemImage = systemImage
            outcome = .none
        case .moveChronologically(let ids, let listID):
            for index in snips.indices where ids.contains(snips[index].id) {
                snips[index].listID = listID
            }
            outcome = .none
        case .deleteList(let id):
            lists.removeAll { $0.id == id }
            for index in snips.indices where snips[index].listID == id {
                snips[index].listID = SnipList.inboxID
            }
            outcome = .none
        case .pruneAttachments:
            outcome = .none
        default:
            throw SnipLibraryError.storeUnavailable
        }
        let update = SnipLibraryUpdate(snapshot: makeSnapshot(sortedBy: sortMode),
                                       outcome: outcome)
        if failsAfterNextWrite {
            failsAfterNextWrite = false
            if failsRecoveryReadAfterNextWrite {
                failsRecoveryReadAfterNextWrite = false
                failsNextCheckedSnapshot = true
            }
            throw CocoaError(.fileWriteUnknown)
        }
        return update
    }

    func failAfterNextWrite() { failsAfterNextWrite = true }

    func failAfterNextWriteAndRecoveryRead() {
        failsAfterNextWrite = true
        failsRecoveryReadAfterNextWrite = true
    }

    func failBeforeNextWriteAndRecoveryRead() {
        failsBeforeNextWrite = true
    }

    func returnFallbackSnapshotAndFailCheckedRead() {
        returnsFallbackSnapshot = true
        failsNextCheckedSnapshot = true
    }

    func failNextCheckedRead(
        recording recovery: SnipRecoverySnapshot? = nil
    ) {
        failsNextCheckedSnapshot = true
        recoveryOnCheckedFailure = recovery
    }

    func waitUntilFirstCommandStarts() async {
        if firstCommandStarted { return }
        await withCheckedContinuation { firstCommandStartWaiters.append($0) }
    }

    func resumeFirstCommand() {
        firstCommandContinuation?.resume()
        firstCommandContinuation = nil
    }

    func recoverySnapshot(in scope: SnipRecoveryScope) -> SnipRecoverySnapshot {
        recovery
    }

    func resolveRecovery(
        _ recoveryID: UUID,
        in scope: SnipRecoveryScope,
        choice: SnipRecoveryChoice
    ) throws -> SnipLibrarySnapshot {
        guard recovery.pendingSnips.contains(where: { $0.id == recoveryID })
            || recovery.pendingLists.contains(where: { $0.id == recoveryID })
        else { throw SnipLibraryError.recoveryNotFound }
        recoveryChoices.append(choice)
        recovery = .empty
        return makeSnapshot(sortedBy: .chronological)
    }

    func replaceText(_ text: String, for id: UUID) {
        guard let index = snips.firstIndex(where: { $0.id == id }) else { return }
        let current = snips[index]
        snips[index] = Snip(
            id: current.id,
            requestID: current.requestID,
            createdAt: current.createdAt,
            updatedAt: current.updatedAt,
            content: text,
            origin: current.origin,
            source: current.source,
            listID: current.listID,
            isDone: current.isDone,
            manualSortKey: current.manualSortKey,
            attachments: current.attachments
        )
    }

    func recordedRecoveryChoices() -> [SnipRecoveryChoice] {
        recoveryChoices
    }
}


struct MacAttachmentPreparationRequest: Equatable, Sendable {
    let id: UUID
    let use: SyncedAttachmentUse
}

enum MacAttachmentPreparationError: Error {
    case unavailable
}

actor MacOptionalCloudSyncHandlerProbe: OptionalCloudSyncHandling {
    private var requests: [MacAttachmentPreparationRequest] = []
    private let urls: [UUID: URL]
    private var failuresRemaining: Int
    private let clearURLs: [URL]
    private var clears = 0
    private var syncCalls = 0

    init(
        urls: [UUID: URL] = [:],
        failuresRemaining: Int = 0,
        clearURLs: [URL] = []
    ) {
        self.urls = urls
        self.failuresRemaining = failuresRemaining
        self.clearURLs = clearURLs
    }

    func refreshAppleAccountNotice() async throws -> AppleAccountNotice? { nil }
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws {}
    func syncWhenPossible() async { syncCalls += 1 }
    func syncCount() -> Int { syncCalls }
    func isCloudSyncActive() async throws -> Bool { true }
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState] { [:] }

    func prepareSyncedAttachment(
        _ id: UUID,
        for use: SyncedAttachmentUse
    ) async throws -> URL {
        requests.append(MacAttachmentPreparationRequest(id: id, use: use))
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw MacAttachmentPreparationError.unavailable
        }
        guard let url = urls[id] else { throw MacAttachmentPreparationError.unavailable }
        return url
    }

    func clearDownloadedFiles() async throws {
        clears += 1
        for url in clearURLs where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func preparationRequests() -> [MacAttachmentPreparationRequest] { requests }
    func clearCount() -> Int { clears }
}
