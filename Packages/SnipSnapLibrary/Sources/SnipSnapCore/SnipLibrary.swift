import Foundation

public enum SnipLibraryError: Error, Equatable, LocalizedError, Sendable {
    case emptyContent
    case snipNotFound
    case invalidStore
    case storeUnavailable
    case requiresMultipleSnips
    case snipChanged
    case duplicateList
    case invalidList
    case invalidCommand
    case attachmentCopyFailed
    case modeTransitionInProgress
    case transferUnsupported
    case transferConflict(SnipLibraryTransferConflict)
    case recoveryNotFound
    case recoveryChanged
    case invalidRecoveryChoice

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            "There is nothing to save."
        case .snipNotFound:
            "That snip no longer exists."
        case .invalidStore:
            "Snip Snap could not read its saved snips."
        case .storeUnavailable:
            "Snip Snap cannot save changes until its snip store is available."
        case .requiresMultipleSnips:
            "Select at least two snips to merge."
        case .snipChanged:
            "This snip changed in another window. Copy your edits, reopen it, and try again."
        case .duplicateList:
            "A list with that name already exists."
        case .invalidList:
            "That list is not available."
        case .invalidCommand:
            "That change cannot run with other changes."
        case .attachmentCopyFailed:
            "Snip Snap could not copy one of the files."
        case .modeTransitionInProgress:
            "This device is changing its storage choice. Try again when setup finishes."
        case .transferUnsupported:
            "This snip store cannot change storage modes."
        case .transferConflict:
            "Snip Snap found records it could not copy safely."
        case .recoveryNotFound:
            "That recovered edit is no longer available."
        case .recoveryChanged:
            "That recovered edit changed. Refresh the review and try again."
        case .invalidRecoveryChoice:
            "That choice does not apply to this recovered edit."
        }
    }
}

public enum SnipAddOutcome: Equatable, Sendable {
    case added(UUID)
    case duplicate
}

public struct SnipLibrarySnapshot: Equatable, Sendable {
    public let snips: [Snip]
    public let lists: [SnipList]
    public let attachmentURLs: [UUID: URL]

    public init(
        snips: [Snip],
        lists: [SnipList],
        attachmentURLs: [UUID: URL] = [:]
    ) {
        self.snips = snips
        self.lists = lists
        self.attachmentURLs = attachmentURLs
    }
}

public enum SnipAttachmentEdit: Equatable, Sendable {
    case existing(attachmentID: UUID)
    case added(sourceURL: URL)
    case replacement(attachmentID: UUID, sourceURL: URL)
}

public struct SnipLibraryExpectation: Sendable {
    public let expectedSnips: [Snip]
    public let absentSnipIDs: Set<UUID>
    public let expectedLists: [SnipList]
    public let absentListIDs: Set<UUID>
    public let requiredListIDs: Set<UUID>
    public let expectedListMemberships: [UUID: Set<UUID>]

    public init(
        expectedSnips: [Snip] = [],
        absentSnipIDs: Set<UUID> = [],
        expectedLists: [SnipList] = [],
        absentListIDs: Set<UUID> = [],
        requiredListIDs: Set<UUID> = [],
        expectedListMemberships: [UUID: Set<UUID>] = [:]
    ) {
        self.expectedSnips = expectedSnips
        self.absentSnipIDs = absentSnipIDs
        self.expectedLists = expectedLists
        self.absentListIDs = absentListIDs
        self.requiredListIDs = requiredListIDs
        self.expectedListMemberships = expectedListMemberships
    }
}

public indirect enum SnipLibraryCommand: Sendable {
    case add(
        content: String,
        origin: SnipOrigin,
        source: SnipSource?,
        listID: UUID,
        attachmentURLs: [URL],
        requestID: UUID,
        now: Date
    )
    case createList(name: String, systemImage: String)
    case restoreList(SnipList)
    case updateList(id: UUID, name: String, systemImage: String)
    case deleteList(id: UUID)
    case update(
        id: UUID,
        content: String,
        attachmentURLs: [URL]?,
        expectedUpdatedAt: Date?,
        now: Date
    )
    case editAttachments(
        snipID: UUID,
        content: String,
        edits: [SnipAttachmentEdit],
        expectedUpdatedAt: Date?,
        now: Date
    )
    case delete(ids: Set<UUID>)
    case restore(snips: [Snip])
    case restoreReplacing(snips: [Snip], id: UUID, expectedUpdatedAt: Date)
    case merge(ids: Set<UUID>, now: Date)
    case setDone(ids: Set<UUID>, done: Bool)
    case toggleDone(id: UUID)
    case toggleDoneMany(ids: Set<UUID>)
    case moveChronologically(ids: [UUID], to: UUID)
    case place(ids: [UUID], in: UUID, before: UUID?, basedOn: SnipSortMode)
    case replaceAll([Snip])
    case pruneAttachments(retaining: Set<UUID>)
    case batch([SnipLibraryCommand])
    case guarded(expectation: SnipLibraryExpectation, command: SnipLibraryCommand)
}

public enum SnipLibraryOutcome: Equatable, Sendable {
    case none
    case add(SnipAddOutcome)
    case listCreated(SnipList)
    case merged(Snip)
}

public struct SnipLibraryUpdate: Equatable, Sendable {
    public let snapshot: SnipLibrarySnapshot
    public let outcome: SnipLibraryOutcome

    public init(snapshot: SnipLibrarySnapshot, outcome: SnipLibraryOutcome) {
        self.snapshot = snapshot
        self.outcome = outcome
    }
}

public enum SnipLibraryTransferConflict: Equatable, Sendable {
    case snipIdentity(UUID)
    case listIdentity(UUID)
    case listName(String)
    case attachmentIdentity(UUID)
}

public struct SnipLibraryTransferSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let snips: [Snip]
    public let lists: [SnipList]
    public let attachmentData: [UUID: Data]
    package let legacyManualPositions: [UUID: Int64]
    package let opaqueSyncStateDigest: Data
    package let opaqueSyncStatePayload: Data

    public init(
        revision: UInt64,
        snips: [Snip],
        lists: [SnipList],
        attachmentData: [UUID: Data]
    ) {
        let state = SnipLibraryState(snips: snips, lists: lists, seenRequestIDs: [])
        self.revision = revision
        self.snips = state.snips
        self.lists = state.lists
        self.attachmentData = attachmentData
        legacyManualPositions = [:]
        opaqueSyncStateDigest = Data()
        opaqueSyncStatePayload = Data()
    }

    package init(
        revision: UInt64,
        snips: [Snip],
        lists: [SnipList],
        attachmentData: [UUID: Data],
        legacyManualPositions: [UUID: Int64],
        opaqueSyncStateDigest: Data = Data(),
        opaqueSyncStatePayload: Data = Data()
    ) {
        let state = SnipLibraryState(snips: snips, lists: lists, seenRequestIDs: [])
        self.revision = revision
        self.snips = state.snips
        self.lists = state.lists
        self.attachmentData = attachmentData
        self.legacyManualPositions = legacyManualPositions
        self.opaqueSyncStateDigest = opaqueSyncStateDigest
        self.opaqueSyncStatePayload = opaqueSyncStatePayload
    }

    package func replacingOpaqueSyncStatePayload(_ payload: Data) -> Self {
        Self(
            revision: revision,
            snips: snips,
            lists: lists,
            attachmentData: attachmentData,
            legacyManualPositions: legacyManualPositions,
            opaqueSyncStateDigest: opaqueSyncStateDigest,
            opaqueSyncStatePayload: payload
        )
    }
}

public struct SnipLibraryTransferResult: Codable, Equatable, Sendable {
    public let approvedSnipIDs: Set<UUID>
    public let recoveredSourceSnipIDs: Set<UUID>

    public init(approvedSnipIDs: Set<UUID>, recoveredSourceSnipIDs: Set<UUID>) {
        self.approvedSnipIDs = approvedSnipIDs
        self.recoveredSourceSnipIDs = recoveredSourceSnipIDs
    }
}

public protocol SnipLibrary: Sendable {
    func snapshot(sortedBy sortMode: SnipSortMode) async -> SnipLibrarySnapshot

    /// Returns a snapshot or reports that the store could not be read.
    func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot

    func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate

    func transferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot

    func mergeTransferSnapshot(
        _ source: SnipLibraryTransferSnapshot,
        transitionID: UUID
    ) async throws -> SnipLibraryTransferResult

    func recoverySnapshot(in scope: SnipRecoveryScope) async throws -> SnipRecoverySnapshot

    @discardableResult
    func resolveRecovery(
        _ id: UUID,
        in scope: SnipRecoveryScope,
        choice: SnipRecoveryChoice
    ) async throws -> SnipLibrarySnapshot
}

public extension SnipLibrary {
    func checkedSnapshot(sortedBy sortMode: SnipSortMode) async throws -> SnipLibrarySnapshot {
        await snapshot(sortedBy: sortMode)
    }

    func transferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot {
        throw SnipLibraryError.transferUnsupported
    }

    func mergeTransferSnapshot(
        _ source: SnipLibraryTransferSnapshot,
        transitionID: UUID
    ) async throws -> SnipLibraryTransferResult {
        throw SnipLibraryError.transferUnsupported
    }

    func recoverySnapshot(in scope: SnipRecoveryScope) async throws -> SnipRecoverySnapshot {
        _ = scope
        return .empty
    }

    @discardableResult
    func resolveRecovery(
        _ id: UUID,
        in scope: SnipRecoveryScope,
        choice: SnipRecoveryChoice
    ) async throws -> SnipLibrarySnapshot {
        _ = (id, scope, choice)
        throw SnipLibraryError.recoveryNotFound
    }
}
