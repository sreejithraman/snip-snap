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
    case attachmentCopyFailed

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
        case .attachmentCopyFailed:
            "Snip Snap could not copy one of the files."
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

public enum SnipLibraryCommand: Sendable {
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
    case updateList(id: UUID, name: String, systemImage: String)
    case deleteList(id: UUID)
    case update(
        id: UUID,
        content: String,
        attachmentURLs: [URL]?,
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

public protocol SnipLibrary: Sendable {
    func snapshot(sortedBy sortMode: SnipSortMode) async -> SnipLibrarySnapshot

    func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) async throws -> SnipLibraryUpdate
}
