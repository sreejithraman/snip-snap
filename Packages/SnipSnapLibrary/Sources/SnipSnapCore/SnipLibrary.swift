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

public struct SyncedAttachmentCacheSnapshot: Equatable, Sendable {
    public let states: [UUID: SyncedAttachmentTransferState]
    public let revision: String

    public init(states: [UUID: SyncedAttachmentTransferState], revision: String) {
        self.states = states
        self.revision = revision
    }
}

public struct SyncedAttachmentReadObservation: Sendable {
    public let source: SnipLibraryReadSource
    public let states: [UUID: SyncedAttachmentTransferState]
    public let publication: SnipLibraryReadPublication?
    private let predecessor: SnipLibraryReadPublication?
    private let libraryBinding: (any SnipLibrary)?

    package init(source: SnipLibraryReadSource, states: [UUID: SyncedAttachmentTransferState],
                 publication: SnipLibraryReadPublication? = nil,
                 predecessor: SnipLibraryReadPublication? = nil, libraryBinding: (any SnipLibrary)? = nil) {
        self.libraryBinding = libraryBinding
        self.source = source
        self.states = states
        self.publication = publication
        self.predecessor = predecessor
    }

    public func matchesApplicationTarget(_ target: SnipLibraryApplicationTarget?) -> Bool {
        guard let target, let binding = libraryBinding as? any SnipLibraryApplicationBinding else { return false }
        return binding.sharesApplicationBinding(with: target.library)
    }

    /// Admission continuity, not publication authority; close `publication` before consuming.
    public func continuesApplication(_ applied: SnipLibraryReadPublication?) -> Bool {
        guard let applied else { return false }
        return predecessor === applied
    }
}

public struct SyncedContentCurrentSyncObservation: Sendable {
    public let source: SnipLibraryReadSource
    public let issue: SyncedContentSyncIssue?
    public let settled: Bool
    public let publication: SnipLibraryReadPublication?
    private let predecessor: SnipLibraryReadPublication?
    private let libraryBinding: (any SnipLibrary)?
    private let snapshot: SnipLibrarySnapshot?
    private let files: Result<[UUID: SnipLibraryFileObservation], any Error>?
    private let recovery: SnipRecoverySnapshot?
    private let states: [UUID: SyncedAttachmentTransferState]?

    package init(source: SnipLibraryReadSource, issue: SyncedContentSyncIssue?, settled: Bool,
                 publication: SnipLibraryReadPublication? = nil,
                 predecessor: SnipLibraryReadPublication? = nil,
                 snapshot: SnipLibrarySnapshot? = nil, recovery: SnipRecoverySnapshot? = nil,
                 states: [UUID: SyncedAttachmentTransferState]? = nil,
                 files: Result<[UUID: SnipLibraryFileObservation], any Error>? = nil,
                 libraryBinding: (any SnipLibrary)? = nil) {
        self.libraryBinding = libraryBinding
        self.files = files
        self.source = source
        self.issue = issue
        self.settled = settled
        self.publication = publication
        self.predecessor = predecessor
        self.snapshot = snapshot
        self.recovery = recovery
        self.states = states
    }

    public func matchesApplicationTarget(_ target: SnipLibraryApplicationTarget?) -> Bool {
        guard let target, let binding = libraryBinding as? any SnipLibraryApplicationBinding else { return false }
        return binding.sharesApplicationBinding(with: target.library)
    }

    /// Prepare the comparison before closing; consume it only while this publication is held.
    public func matchesApplication(
        _ applied: SnipLibrarySnapshot,
        after publication: SnipLibraryReadPublication?, target: SnipLibraryApplicationTarget?, recovery: SnipRecoverySnapshot,
        files appliedFiles: Result<[UUID: SnipLibraryFileObservation], any Error>?,
        attachmentStates: [UUID: SyncedAttachmentTransferState]? = nil
    ) -> Bool {
        guard publication != nil, let snapshot, self.recovery == recovery,
          matchesApplicationTarget(target),
          case .success(let currentFiles) = files, case .success(let knownFiles) = appliedFiles,
          currentFiles == knownFiles else { return false }
        let orderSnips: (Snip, Snip) -> Bool = { $0.id.uuidString < $1.id.uuidString }
        let orderLists: (SnipList, SnipList) -> Bool = { $0.id.uuidString < $1.id.uuidString }
        guard applied.snips.sorted(by: orderSnips) == snapshot.snips.sorted(by: orderSnips),
          applied.lists.sorted(by: orderLists) == snapshot.lists.sorted(by: orderLists),
          applied.attachmentURLs == snapshot.attachmentURLs else { return false }
        if let attachmentStates { return states == attachmentStates }
        return true
    }
}

/// One main-app owner for optional sync and verified, on-demand attachment files.
public protocol OptionalCloudSyncHandling: AppleAccountCacheHandling {
    func syncWhenPossible() async
    func retrySyncWhenPossible() async
    func retrySyncWithOutcome() async throws -> SyncedContentActionOutcome
    func scheduleSyncAfterLocalChange() async
    func isCloudSyncActive() async throws -> Bool
    func syncedAttachmentStates() async throws -> [UUID: SyncedAttachmentTransferState]
    func checkedAttachmentStates() async throws -> SyncedAttachmentReadObservation
    func checkedCurrentSyncStatus(for source: SnipLibraryReadSource) async throws -> SyncedContentCurrentSyncObservation
    func prepareSyncedAttachment(_ id: UUID, for use: SyncedAttachmentUse) async throws -> URL
    func clearDownloadedFiles() async throws
    func downloadedAttachmentCache(in scope: SnipRecoveryScope) async throws -> SyncedAttachmentCacheSnapshot
    func clearDownloadedFiles(ifRevision revision: String, in scope: SnipRecoveryScope) async throws -> Bool
}

public extension OptionalCloudSyncHandling {
    func checkedAttachmentStates() async throws -> SyncedAttachmentReadObservation {
        throw SnipLibraryError.transferUnsupported
    }

    func checkedCurrentSyncStatus(for source: SnipLibraryReadSource) async throws -> SyncedContentCurrentSyncObservation {
        throw SnipLibraryError.transferUnsupported
    }

    func retrySyncWithOutcome() async throws -> SyncedContentActionOutcome {
        .notRun(.unsupportedLegacyHandler)
    }

    func downloadedAttachmentCache(in scope: SnipRecoveryScope) async throws -> SyncedAttachmentCacheSnapshot {
        throw SnipLibraryError.transferUnsupported
    }

    func clearDownloadedFiles(ifRevision revision: String, in scope: SnipRecoveryScope) async throws -> Bool {
        throw SnipLibraryError.transferUnsupported
    }

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
            String(localized: "Add text or an attachment to save a snip.", bundle: .main)
        case .snipNotFound:
            String(localized: "That snip no longer exists.", bundle: .main)
        case .invalidStore:
            String(localized: "Snip Snap couldn’t open your saved snips.", bundle: .main)
        case .storeUnavailable:
            String(localized: "Snip Snap can’t save changes right now. Try again soon.", bundle: .main)
        case .requiresMultipleSnips:
            String(localized: "Select at least two snips to merge.", bundle: .main)
        case .snipChanged:
            String(localized: "This snip changed in another window. Copy your edits, reopen it, and try again.", bundle: .main)
        case .duplicateList:
            String(localized: "A list with that name already exists. Choose another name.", bundle: .main)
        case .invalidList:
            String(localized: "That list is not available.", bundle: .main)
        case .invalidCommand:
            String(localized: "These changes can’t be made together.", bundle: .main)
        case .attachmentCopyFailed:
            String(localized: "Couldn’t copy an attachment. Try again.", bundle: .main)
        case .modeTransitionInProgress:
            String(localized: "Can’t change your snips right now. Try again in a moment. If it still fails, contact support.", bundle: .main)
        case .readOnlyRecovery:
            String(localized: "You can’t edit this recovery copy.", bundle: .main)
        case .transferUnsupported:
            String(localized: "This library can’t change where it stores your snips.", bundle: .main)
        case .transferConflict:
            String(localized: "Snip Snap found items it can’t copy safely.", bundle: .main)
        case .recoveryNotFound:
            String(localized: "That recovered version is no longer available.", bundle: .main)
        case .recoveryChanged:
            String(localized: "That recovered version changed. Reopen it and try again.", bundle: .main)
        case .invalidRecoveryChoice:
            String(localized: "That choice doesn’t apply to this recovered version.", bundle: .main)
        case .importChanged:
            String(localized: "The backup or saved snips changed. Review the import again.", bundle: .main)
        case .deviceActionChanged:
            String(localized: "Can’t undo this action. The same details changed on another device.", bundle: .main)
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

public struct SnipLibraryReadSource: Equatable, Sendable {
    public let storeID: UUID
    public let storageMode: SyncedContentMode
    public let namespaceKey: String?

    package init(storeID: UUID, storageMode: SyncedContentMode, namespaceKey: String?) {
        self.storeID = storeID
        self.storageMode = storageMode
        self.namespaceKey = namespaceKey
    }
}

public struct SnipLibraryFileObservation: Equatable, Sendable {
    public let url: URL
    public let kind: String?
    public let device: UInt64?
    public let fileNumber: UInt64?
    public let byteCount: UInt64?
    public let modifiedAt: Date?

    package init(url: URL, kind: String?, device: UInt64?, fileNumber: UInt64?, byteCount: UInt64?, modifiedAt: Date?) {
        self.url = url; self.kind = kind; self.device = device; self.fileNumber = fileNumber
        self.byteCount = byteCount; self.modifiedAt = modifiedAt
    }
}

public struct SnipLibraryReadObservation: Sendable {
    public let snapshot: SnipLibrarySnapshot
    public let source: SnipLibraryReadSource?
    public let publication: SnipLibraryReadPublication?
    public let target: SnipLibraryApplicationTarget?
    public let files: Result<[UUID: SnipLibraryFileObservation], any Error>?

    package init(snapshot: SnipLibrarySnapshot, source: SnipLibraryReadSource?,
                 publication: SnipLibraryReadPublication? = nil, target: SnipLibraryApplicationTarget? = nil,
                 files: Result<[UUID: SnipLibraryFileObservation], any Error>? = nil) {
        self.files = files
        self.target = target
        self.snapshot = snapshot
        self.source = source
        self.publication = publication
    }
}

/// Historical operation target. Its managed library rejects access after this source is retired.
public final class SnipLibraryApplicationTarget: Sendable {
    public let source: SnipLibraryReadSource
    public let library: any SnipLibrary
    public let recoveryScope: SnipRecoveryScope?

    package init(source: SnipLibraryReadSource, library: any SnipLibrary, recoveryScope: SnipRecoveryScope?) {
        self.source = source; self.library = library; self.recoveryScope = recoveryScope
    }
}

package protocol SnipLibraryApplicationBinding: SnipLibrary {
    nonisolated var initialApplicationTarget: SnipLibraryApplicationTarget? { get }
    /// Compares immutable producer bindings, without asserting either is current.
    nonisolated func sharesApplicationBinding(with library: any SnipLibrary) -> Bool
}

public extension SnipLibraryApplicationTarget {
    static func initial(for library: any SnipLibrary) -> SnipLibraryApplicationTarget? {
        (library as? any SnipLibraryApplicationBinding)?.initialApplicationTarget
    }
}

public enum SnipLibraryReadPublicationError: Error, Sendable {
    case revoked
}

/// Serializes a prepared, callback-free application install with source retirement.
public final class SnipLibraryReadPublication: @unchecked Sendable {
    private let lock = NSLock()
    private enum State { case pending, available, revoked }
    private var state: State

    package init(pending: Bool = false) { state = pending ? .pending : .available }
    package var isRevoked: Bool { lock.withLock { if case .revoked = state { true } else { false } } }
    @discardableResult
    package func revoke() -> Bool {
        lock.withLock {
            let wasAvailable: Bool = if case .available = state { true } else { false }
            state = .revoked
            return wasAvailable
        }
    }
    package func completeRead() {
        lock.withLock { if case .pending = state { state = .available } }
    }

    /// Finish synchronously on the acquiring thread, before callbacks or suspension.
    public func beginApplication() throws -> Application {
        lock.lock()
        guard case .available = state else {
            lock.unlock()
            throw SnipLibraryReadPublicationError.revoked
        }
        return Application(publication: self)
    }

    public final class Application {
        private var publication: SnipLibraryReadPublication?
        fileprivate init(publication: SnipLibraryReadPublication) { self.publication = publication }
        func owns(_ expected: SnipLibraryReadPublication) -> Bool { publication === expected }
        public func finish() {
            guard let publication else { return }
            self.publication = nil
            publication.lock.unlock()
        }
        deinit { finish() }
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
    /// Guards identity, text, ordered attachments, pin and Done state while allowing metadata refreshes.
    public let expectedCompletionSnips: [Snip]
    public let absentSnipIDs: Set<UUID>
    public let expectedLists: [SnipList]
    public let absentListIDs: Set<UUID>
    public let requiredListIDs: Set<UUID>
    public let expectedListMemberships: [UUID: Set<UUID>]

    public init(
        expectedSnips: [Snip] = [],
        expectedCompletionSnips: [Snip] = [],
        absentSnipIDs: Set<UUID> = [],
        expectedLists: [SnipList] = [],
        absentListIDs: Set<UUID> = [],
        requiredListIDs: Set<UUID> = [],
        expectedListMemberships: [UUID: Set<UUID>] = [:]
    ) {
        self.expectedSnips = expectedSnips
        self.expectedCompletionSnips = expectedCompletionSnips
        self.absentSnipIDs = absentSnipIDs
        self.expectedLists = expectedLists
        self.absentListIDs = absentListIDs
        self.requiredListIDs = requiredListIDs
        self.expectedListMemberships = expectedListMemberships
    }
}

public enum SnipListNamePolicy: Equatable, Sendable {
    case exact
    case available
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
    case createList(
        name: String, systemImage: String, color: SnipListColorPreset? = nil,
        namePolicy: SnipListNamePolicy = .exact
    )
    case restoreList(SnipList)
    case updateList(id: UUID, name: String, systemImage: String, color: SnipListColorChange = .keep)
    case deleteList(id: UUID)
    case moveList(id: UUID, before: UUID?)
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
    case setPinned(ids: Set<UUID>, pinned: Bool)
    case togglePinned(id: UUID)
    case setDone(ids: Set<UUID>, done: Bool)
    case toggleDone(id: UUID)
    case toggleDoneMany(ids: Set<UUID>)
    case moveChronologically(ids: [UUID], to: UUID)
    case place(ids: [UUID], in: UUID, before: UUID?, basedOn: SnipSortMode)
    case replaceAll([Snip])
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
    // Backup-only request history merges monotonically into local metadata. Content,
    // target, and plan digests omit it to preserve persisted sync formats and allow
    // concurrent request-history additions without invalidating an import preview.
    package let additionalSeenRequestIDs: Set<UUID>

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
        additionalSeenRequestIDs = []
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
        opaqueSyncStatePayload: Data = Data(),
        additionalSeenRequestIDs: Set<UUID> = []
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
        self.additionalSeenRequestIDs = additionalSeenRequestIDs
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
            opaqueSyncStatePayload: payload,
            additionalSeenRequestIDs: additionalSeenRequestIDs
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

package protocol SnipLibraryReadObserving: SnipLibrary {
    func checkedRead(sortedBy sortMode: SnipSortMode) async throws -> SnipLibraryReadObservation
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

    @discardableResult
    func resolveRecovery(
        _ id: UUID,
        in scope: SnipRecoveryScope,
        choice: SnipRecoveryChoice,
        expectation: SnipRecoveryExpectation?
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

    @discardableResult
    func resolveRecovery(
        _ id: UUID,
        in scope: SnipRecoveryScope,
        choice: SnipRecoveryChoice,
        expectation: SnipRecoveryExpectation?
    ) async throws -> SnipLibrarySnapshot {
        // Adapters that cannot check a guard atomically must reject it.
        guard expectation == nil else { throw SnipLibraryError.invalidCommand }
        return try await resolveRecovery(id, in: scope, choice: choice)
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
