import Foundation

public enum AppleAccountCacheChoice: Equatable, Sendable {
    case keepLocalCopy
    case remove
}

public protocol AppleAccountCacheHandling: Sendable {
    func refreshAppleAccountNotice() async throws -> AppleAccountNotice?
    func resolveAppleAccountCache(_ choice: AppleAccountCacheChoice) async throws
}

public enum SyncedAttachmentUse: Equatable, Sendable {
    case preview
    case open
    case copy
    case export
}

public enum SyncedAttachmentTransferState: Equatable, Sendable {
    case waiting
    case syncing
    case failed
    case available
}

/// One main-app owner for optional sync and verified, on-demand attachment files.
public protocol OptionalCloudSyncHandling: AppleAccountCacheHandling {
    func syncWhenPossible() async
    func retrySyncWhenPossible() async
    func scheduleSyncAfterLocalChange() async
    func isCloudSyncActive() async throws -> Bool
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState]
    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL
    func clearDownloadedFiles() async throws
}

public extension OptionalCloudSyncHandling {
    func retrySyncWhenPossible() async {
        await syncWhenPossible()
    }

    func scheduleSyncAfterLocalChange() async {
        await syncWhenPossible()
    }
}

public enum AppleAccountNotice: Equatable, Sendable {
    case paused
    case signedOut
    case accountChanged
}

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
    case readOnlyRecovery
    case transferUnsupported
    case transferConflict(SnipLibraryTransferConflict)
    case recoveryNotFound
    case recoveryChanged
    case invalidRecoveryChoice
    case importChanged
    case deviceActionChanged

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            String(localized: "There is nothing to save.", bundle: .main)
        case .snipNotFound:
            String(localized: "That snip no longer exists.", bundle: .main)
        case .invalidStore:
            String(localized: "Snip Snap could not read its saved snips.", bundle: .main)
        case .storeUnavailable:
            String(localized: "Snip Snap cannot save changes until its snip store is available.", bundle: .main)
        case .requiresMultipleSnips:
            String(localized: "Select at least two snips to merge.", bundle: .main)
        case .snipChanged:
            String(localized: "This snip changed in another window. Copy your edits, reopen it, and try again.", bundle: .main)
        case .duplicateList:
            String(localized: "A list with that name already exists.", bundle: .main)
        case .invalidList:
            String(localized: "That list is not available.", bundle: .main)
        case .invalidCommand:
            String(localized: "That change cannot run with other changes.", bundle: .main)
        case .attachmentCopyFailed:
            String(localized: "Snip Snap could not copy one of the files.", bundle: .main)
        case .modeTransitionInProgress:
            String(localized: "This device is changing its storage choice. Try again when setup finishes.", bundle: .main)
        case .readOnlyRecovery:
            String(localized: "This is a recovery copy. Restore it to an active library before making changes.", bundle: .main)
        case .transferUnsupported:
            String(localized: "This snip store cannot change storage modes.", bundle: .main)
        case .transferConflict:
            String(localized: "Snip Snap found records it could not copy safely.", bundle: .main)
        case .recoveryNotFound:
            String(localized: "That recovered edit is no longer available.", bundle: .main)
        case .recoveryChanged:
            String(localized: "That recovered edit changed. Refresh the review and try again.", bundle: .main)
        case .invalidRecoveryChoice:
            String(localized: "That choice does not apply to this recovered edit.", bundle: .main)
        case .importChanged:
            String(localized: "The backup or saved snips changed. Review the import again.", bundle: .main)
        case .deviceActionChanged:
            String(localized: "That action cannot be undone because the same fields changed on another device.", bundle: .main)
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

public struct SnipLibraryArchive: Sendable {
    public let snips: [Snip]
    public let lists: [SnipList]
    public let seenRequestIDs: Set<UUID>
    public let attachmentURLs: [UUID: URL]

    public init(
        snips: [Snip],
        lists: [SnipList],
        seenRequestIDs: Set<UUID>,
        attachmentURLs: [UUID: URL]
    ) {
        self.snips = snips
        self.lists = lists
        self.seenRequestIDs = seenRequestIDs
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
    case createList(name: String, systemImage: String, color: SnipListColor? = nil)
    case restoreList(SnipList)
    case updateList(id: UUID, name: String, systemImage: String, color: SnipListColorChange = .keep)
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
    case importArchive(SnipLibraryArchive)
    case applyDevicePatch(SnipLibraryDevicePatch, now: Date)
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
    package let devicePatch: SnipLibraryDevicePatch?

    public init(snapshot: SnipLibrarySnapshot, outcome: SnipLibraryOutcome) {
        self.snapshot = snapshot
        self.outcome = outcome
        devicePatch = nil
    }

    package init(
        snapshot: SnipLibrarySnapshot,
        outcome: SnipLibraryOutcome,
        devicePatch: SnipLibraryDevicePatch
    ) {
        self.snapshot = snapshot
        self.outcome = outcome
        self.devicePatch = devicePatch
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
    package let attachmentFileURLs: [UUID: URL]
    package let attachmentFileDigests: [UUID: Data]
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
        attachmentFileURLs = [:]
        attachmentFileDigests = [:]
        legacyManualPositions = [:]
        opaqueSyncStateDigest = Data()
        opaqueSyncStatePayload = Data()
    }

    package init(
        revision: UInt64,
        snips: [Snip],
        lists: [SnipList],
        attachmentData: [UUID: Data],
        attachmentFileURLs: [UUID: URL] = [:],
        attachmentFileDigests: [UUID: Data] = [:],
        legacyManualPositions: [UUID: Int64],
        opaqueSyncStateDigest: Data = Data(),
        opaqueSyncStatePayload: Data = Data()
    ) {
        let state = SnipLibraryState(snips: snips, lists: lists, seenRequestIDs: [])
        self.revision = revision
        self.snips = state.snips
        self.lists = state.lists
        self.attachmentData = attachmentData
        self.attachmentFileURLs = attachmentFileURLs
        self.attachmentFileDigests = attachmentFileDigests
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
            attachmentFileURLs: attachmentFileURLs,
            attachmentFileDigests: attachmentFileDigests,
            legacyManualPositions: legacyManualPositions,
            opaqueSyncStateDigest: opaqueSyncStateDigest,
            opaqueSyncStatePayload: payload
        )
    }
}

package final class SnipImportStagingLease: @unchecked Sendable {
    package let rootURL: URL
    private let cleanup: @Sendable () throws -> Void
    private let lock = NSLock()
    private var isReleased = false

    package init(
        rootURL: URL,
        cleanup: @escaping @Sendable () throws -> Void
    ) {
        self.rootURL = rootURL
        self.cleanup = cleanup
    }

    package func release() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isReleased else { return }
        try cleanup()
        isReleased = true
    }

    deinit {
        try? release()
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

public struct SnipImportPreview: Equatable, Sendable {
    public let totalSnipCount: Int
    public let addedSnipCount: Int
    public let recoveredSnipCount: Int
    public let addedListCount: Int
    public let addedAttachmentCount: Int
    package let transitionID: UUID
    package let source: SnipLibraryTransferSnapshot
    package let targetDigest: Data
    package let devicePatch: SnipLibraryDevicePatch
    package let stagingLease: SnipImportStagingLease?

    package var stagedAttachmentURLs: [UUID: URL] { source.attachmentFileURLs }
    package var stagingRootURL: URL? { stagingLease?.rootURL }

    package init(
        totalSnipCount: Int,
        addedSnipCount: Int,
        recoveredSnipCount: Int,
        addedListCount: Int,
        addedAttachmentCount: Int,
        transitionID: UUID,
        source: SnipLibraryTransferSnapshot,
        targetDigest: Data,
        devicePatch: SnipLibraryDevicePatch,
        stagingLease: SnipImportStagingLease? = nil
    ) {
        self.totalSnipCount = totalSnipCount
        self.addedSnipCount = addedSnipCount
        self.recoveredSnipCount = recoveredSnipCount
        self.addedListCount = addedListCount
        self.addedAttachmentCount = addedAttachmentCount
        self.transitionID = transitionID
        self.source = source
        self.targetDigest = targetDigest
        self.devicePatch = devicePatch
        self.stagingLease = stagingLease
    }

    package func withStagingLease(_ lease: SnipImportStagingLease) -> Self {
        Self(
            totalSnipCount: totalSnipCount,
            addedSnipCount: addedSnipCount,
            recoveredSnipCount: recoveredSnipCount,
            addedListCount: addedListCount,
            addedAttachmentCount: addedAttachmentCount,
            transitionID: transitionID,
            source: source,
            targetDigest: targetDigest,
            devicePatch: devicePatch,
            stagingLease: lease
        )
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.totalSnipCount == rhs.totalSnipCount
            && lhs.addedSnipCount == rhs.addedSnipCount
            && lhs.recoveredSnipCount == rhs.recoveredSnipCount
            && lhs.addedListCount == rhs.addedListCount
            && lhs.addedAttachmentCount == rhs.addedAttachmentCount
            && lhs.transitionID == rhs.transitionID
            && lhs.source == rhs.source
            && lhs.targetDigest == rhs.targetDigest
            && lhs.devicePatch == rhs.devicePatch
    }
}

public struct SnipImportResult: Equatable, Sendable {
    public let snapshot: SnipLibrarySnapshot
    public let addedSnipCount: Int
    public let recoveredSnipCount: Int
    package let devicePatch: SnipLibraryDevicePatch?

    public init(
        snapshot: SnipLibrarySnapshot,
        addedSnipCount: Int,
        recoveredSnipCount: Int
    ) {
        self.snapshot = snapshot
        self.addedSnipCount = addedSnipCount
        self.recoveredSnipCount = recoveredSnipCount
        devicePatch = nil
    }

    package init(
        snapshot: SnipLibrarySnapshot,
        addedSnipCount: Int,
        recoveredSnipCount: Int,
        devicePatch: SnipLibraryDevicePatch
    ) {
        self.snapshot = snapshot
        self.addedSnipCount = addedSnipCount
        self.recoveredSnipCount = recoveredSnipCount
        self.devicePatch = devicePatch
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

    func previewTransferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot

    func mergeTransferSnapshot(
        _ source: SnipLibraryTransferSnapshot,
        transitionID: UUID,
        expectedTargetDigest: Data?
    ) async throws -> SnipLibraryTransferResult

    func previewImport(
        _ source: SnipLibraryTransferSnapshot,
        transitionID: UUID
    ) async throws -> SnipImportPreview

    func applyImport(_ preview: SnipImportPreview) async throws -> SnipImportResult

    func recoverySnapshot(in scope: SnipRecoveryScope) async throws -> SnipRecoverySnapshot

    @discardableResult
    func resolveRecovery(
        _ id: UUID,
        in scope: SnipRecoveryScope,
        choice: SnipRecoveryChoice
    ) async throws -> SnipLibrarySnapshot

    func archive() async throws -> SnipLibraryArchive
}

public extension SnipLibrary {
    func transferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot {
        throw SnipLibraryError.transferUnsupported
    }

    func previewTransferSnapshot(revision: UInt64) async throws -> SnipLibraryTransferSnapshot {
        try await transferSnapshot(revision: revision)
    }

    func mergeTransferSnapshot(
        _ source: SnipLibraryTransferSnapshot,
        transitionID: UUID,
        expectedTargetDigest: Data?
    ) async throws -> SnipLibraryTransferResult {
        _ = (source, transitionID, expectedTargetDigest)
        throw SnipLibraryError.transferUnsupported
    }

    func mergeTransferSnapshot(
        _ source: SnipLibraryTransferSnapshot,
        transitionID: UUID
    ) async throws -> SnipLibraryTransferResult {
        try await mergeTransferSnapshot(
            source,
            transitionID: transitionID,
            expectedTargetDigest: nil
        )
    }

    func previewImport(
        _ source: SnipLibraryTransferSnapshot,
        transitionID: UUID
    ) async throws -> SnipImportPreview {
        _ = (source, transitionID)
        throw SnipLibraryError.transferUnsupported
    }

    func applyImport(_ preview: SnipImportPreview) async throws -> SnipImportResult {
        _ = preview
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

    func archive() async throws -> SnipLibraryArchive {
        let snapshot = await snapshot(sortedBy: .manual)
        return SnipLibraryArchive(
            snips: snapshot.snips,
            lists: snapshot.lists,
            seenRequestIDs: Set(snapshot.snips.map(\.requestID)),
            attachmentURLs: snapshot.attachmentURLs
        )
    }
}
