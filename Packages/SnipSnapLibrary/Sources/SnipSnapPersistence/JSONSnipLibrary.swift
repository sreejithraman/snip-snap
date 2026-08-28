import Foundation
import SnipSnapCore
import UniformTypeIdentifiers

public actor JSONSnipLibrary: SnipLibrary {
    private struct Document: Codable {
        let version: Int
        var snips: [Snip]
        var lists: [SnipList]
        var seenRequestIDs: Set<UUID>

        private enum CodingKeys: String, CodingKey {
            case version
            case snips
            case lists
            case seenRequestIDs
            case legacyItems = "items"
            case legacySections = "sections"
        }

        init(
            version: Int,
            snips: [Snip],
            lists: [SnipList],
            seenRequestIDs: Set<UUID>
        ) {
            self.version = version
            self.snips = snips
            self.lists = lists
            self.seenRequestIDs = seenRequestIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            snips = try container.decodeIfPresent([Snip].self, forKey: .snips)
                ?? container.decode([Snip].self, forKey: .legacyItems)
            lists = try container.decodeIfPresent([SnipList].self, forKey: .lists)
                ?? container.decode([SnipList].self, forKey: .legacySections)
            let storedRequestIDs = try container.decodeIfPresent(
                [UUID].self,
                forKey: .seenRequestIDs
            ) ?? []
            seenRequestIDs = Set(storedRequestIDs).union(snips.map(\.requestID))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(snips, forKey: .snips)
            try container.encode(lists, forKey: .lists)
            try container.encode(
                seenRequestIDs.sorted { $0.uuidString < $1.uuidString },
                forKey: .seenRequestIDs
            )
        }
    }

    static let currentVersion = 6
    // TODO: Remove version 4 decoding after the 1.0 migration window.
    private static let legacyVersion = 4

    private let fileURL: URL
    nonisolated let attachmentRootURL: URL
    private let isAvailable: Bool
    private var snips: [Snip]
    private var lists: [SnipList]
    private var knownAttachmentPaths: [UUID: String]
    // Keep request IDs in the store so delayed retries cannot recreate a snip
    // after the user removes it or the repository reopens.
    private var seenRequestIDs: Set<UUID>

    public init(fileURL: URL = JSONSnipLibrary.defaultStoreURL()) throws {
        try Self.moveLegacyStoreIfNeeded(to: fileURL)
        self.fileURL = fileURL
        attachmentRootURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Attachments", isDirectory: true)
        isAvailable = true

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            snips = []
            lists = [.inbox]
            knownAttachmentPaths = [:]
            seenRequestIDs = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: data)
            guard document.version == Self.currentVersion
                    || document.version == Self.legacyVersion else {
                throw SnipLibraryError.invalidStore
            }
            snips = document.snips
            lists = Self.validatedLists(document.lists, snips: snips)
            knownAttachmentPaths = Dictionary(
                snips.flatMap(\.attachments).map { ($0.id, $0.relativePath) },
                uniquingKeysWith: { first, _ in first }
            )
            guard !lists.isEmpty else { throw SnipLibraryError.invalidStore }
            seenRequestIDs = document.seenRequestIDs
            if document.version == Self.legacyVersion {
                try Self.write(
                    snips: snips,
                    lists: lists,
                    seenRequestIDs: seenRequestIDs,
                    to: fileURL
                )
            }
        } catch let error as SnipLibraryError {
            throw error
        } catch {
            throw SnipLibraryError.invalidStore
        }
        Self.removeUnreferencedAttachmentDirectories(
            at: attachmentRootURL,
            keeping: Set(snips.flatMap(\.attachments).map(\.relativePath))
        )
    }

    private init(unavailableAt fileURL: URL) {
        self.fileURL = fileURL
        attachmentRootURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Attachments", isDirectory: true)
        isAvailable = false
        snips = []
        lists = [.inbox]
        knownAttachmentPaths = [:]
        seenRequestIDs = []
    }

    public static func openRecoveringCorruptStore(
        fileURL: URL = JSONSnipLibrary.defaultStoreURL()
    ) throws -> (repository: JSONSnipLibrary, backupURL: URL?) {
        do {
            return (try JSONSnipLibrary(fileURL: fileURL), nil)
        } catch SnipLibraryError.invalidStore {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw SnipLibraryError.invalidStore
            }
            let recoveryID = UUID().uuidString
            let parentURL = fileURL.deletingLastPathComponent()
            let backupURL = parentURL
                .appendingPathComponent(
                    "snips.corrupt-\(recoveryID).json",
                    isDirectory: false
                )
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            let attachmentURL = parentURL.appendingPathComponent("Attachments", isDirectory: true)
            if FileManager.default.fileExists(atPath: attachmentURL.path) {
                let backupAttachmentURL = parentURL.appendingPathComponent(
                    "Attachments.corrupt-\(recoveryID)",
                    isDirectory: true
                )
                do {
                    try FileManager.default.moveItem(at: attachmentURL, to: backupAttachmentURL)
                } catch {
                    try? FileManager.default.moveItem(at: backupURL, to: fileURL)
                    throw error
                }
            }
            return (try JSONSnipLibrary(fileURL: fileURL), backupURL)
        }
    }

    public static func unavailable(
        fileURL: URL = JSONSnipLibrary.defaultStoreURL()
    ) -> JSONSnipLibrary {
        JSONSnipLibrary(unavailableAt: fileURL)
    }

    public static func defaultStoreURL(fileManager: FileManager = .default) -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["SNIP_SNAP_STORE_PATH"],
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: false)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Snip Snap", isDirectory: true)
            .appendingPathComponent("snips.json", isDirectory: false)
    }

    private static func moveLegacyStoreIfNeeded(to fileURL: URL) throws {
        // TODO: Remove items.json migration after the 1.0 migration window.
        guard fileURL.lastPathComponent == "snips.json",
              !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let legacyURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("items.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        try FileManager.default.moveItem(at: legacyURL, to: fileURL)
    }

    public func snapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        makeSnapshot(sortedBy: sortMode)
    }

    public func perform(
        _ command: SnipLibraryCommand,
        sortedBy sortMode: SnipSortMode
    ) throws -> SnipLibraryUpdate {
        try ensureAvailable()
        var state = SnipLibraryState(
            snips: snips,
            lists: lists,
            seenRequestIDs: seenRequestIDs
        )
        var createdDirectories: [URL] = []
        let outcome: SnipLibraryOutcome
        do {
            outcome = try state.perform(
                command,
                prepareAttachments: { sourceURLs, currentSnips in
                    let prepared = try self.prepareAttachments(
                        sourceURLs,
                        currentSnips: currentSnips
                    )
                    createdDirectories.append(contentsOf: prepared.createdDirectories)
                    return prepared.attachments
                },
                pruneAttachments: { retainedIDs, currentSnips in
                    let liveIDs = Set(currentSnips.flatMap(\.attachments).map(\.id))
                        .union(retainedIDs)
                    let retainedPaths = Set(liveIDs.compactMap { self.knownAttachmentPaths[$0] })
                    self.removeUnreferencedAttachments(
                        currentSnips: currentSnips,
                        keepingAdditional: retainedPaths
                    )
                    self.knownAttachmentPaths = self.knownAttachmentPaths.filter {
                        liveIDs.contains($0.key)
                    }
                }
            )
            if snips != state.snips
                || lists != state.lists
                || seenRequestIDs != state.seenRequestIDs
            {
                try persistMutation {
                    snips = state.snips
                    lists = state.lists
                    seenRequestIDs = state.seenRequestIDs
                }
            } else {
                seenRequestIDs = state.seenRequestIDs
            }
        } catch {
            removeAttachmentDirectories(createdDirectories)
            throw error
        }

        knownAttachmentPaths.merge(
            snips.flatMap(\.attachments).map { ($0.id, $0.relativePath) },
            uniquingKeysWith: { _, latest in latest }
        )

        return SnipLibraryUpdate(
            snapshot: makeSnapshot(sortedBy: sortMode),
            outcome: outcome
        )
    }

    private func makeSnapshot(sortedBy sortMode: SnipSortMode) -> SnipLibrarySnapshot {
        let orderedSnips = allSnips(sortMode: sortMode)
        return SnipLibrarySnapshot(
            snips: orderedSnips,
            lists: allLists(),
            attachmentURLs: Dictionary(
                orderedSnips.flatMap(\.attachments).map { attachment in
                    (attachment.id, attachmentURL(for: attachment))
                },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    func allSnips(sortMode: SnipSortMode = .chronological) -> [Snip] {
        SnipLibraryState(snips: snips, lists: lists, seenRequestIDs: seenRequestIDs)
            .allSnips(sortMode: sortMode)
    }

    func allLists() -> [SnipList] {
        SnipLibraryState(snips: snips, lists: lists, seenRequestIDs: seenRequestIDs).allLists()
    }

    @discardableResult
    func add(
        content: String,
        origin: SnipOrigin,
        source: SnipSource? = nil,
        listID: UUID = SnipList.inboxID,
        attachmentURLs: [URL] = [],
        requestID: UUID = UUID(),
        now: Date = Date()
    ) throws -> Snip? {
        let update = try perform(
            .add(
                content: content,
                origin: origin,
                source: source,
                listID: listID,
                attachmentURLs: attachmentURLs,
                requestID: requestID,
                now: now
            ),
            sortedBy: .chronological
        )
        guard case .add(.added(let id)) = update.outcome else { return nil }
        return update.snapshot.snips.first { $0.id == id }
    }

    func createList(name: String, systemImage: String) throws -> SnipList {
        let update = try perform(
            .createList(name: name, systemImage: systemImage),
            sortedBy: .chronological
        )
        guard case .listCreated(let list) = update.outcome else {
            throw SnipLibraryError.invalidList
        }
        return list
    }

    func updateList(id: UUID, name: String, systemImage: String) throws {
        _ = try perform(.updateList(id: id, name: name, systemImage: systemImage), sortedBy: .manual)
    }

    func deleteList(id: UUID) throws {
        _ = try perform(.deleteList(id: id), sortedBy: .manual)
    }

    func update(
        id: UUID,
        content: String,
        attachmentURLs: [URL]? = nil,
        expectedUpdatedAt: Date? = nil,
        now: Date = Date()
    ) throws {
        _ = try perform(
            .update(
                id: id,
                content: content,
                attachmentURLs: attachmentURLs,
                expectedUpdatedAt: expectedUpdatedAt,
                now: now
            ),
            sortedBy: .manual
        )
    }

    func delete(ids: Set<UUID>) throws {
        _ = try perform(.delete(ids: ids), sortedBy: .manual)
    }

    func restore(snips: [Snip]) throws {
        _ = try perform(.restore(snips: snips), sortedBy: .manual)
    }

    func restore(
        snips: [Snip],
        replacing id: UUID,
        expectedUpdatedAt: Date
    ) throws {
        _ = try perform(
            .restoreReplacing(snips: snips, id: id, expectedUpdatedAt: expectedUpdatedAt),
            sortedBy: .manual
        )
    }

    func merge(ids: Set<UUID>, now: Date = Date()) throws -> Snip {
        let update = try perform(.merge(ids: ids, now: now), sortedBy: .manual)
        guard case .merged(let snip) = update.outcome else {
            throw SnipLibraryError.requiresMultipleSnips
        }
        return snip
    }

    func setDone(ids: Set<UUID>, done: Bool) throws {
        _ = try perform(.setDone(ids: ids, done: done), sortedBy: .manual)
    }

    func toggleDone(id: UUID) throws {
        _ = try perform(.toggleDone(id: id), sortedBy: .manual)
    }

    func toggleDone(ids: Set<UUID>) throws {
        _ = try perform(.toggleDoneMany(ids: ids), sortedBy: .manual)
    }

    func moveChronologically(ids: [UUID], to listID: UUID) throws {
        _ = try perform(.moveChronologically(ids: ids, to: listID), sortedBy: .manual)
    }

    func place(
        ids: [UUID],
        in listID: UUID,
        before destinationID: UUID?,
        basedOn sortMode: SnipSortMode = .manual
    ) throws {
        _ = try perform(
            .place(ids: ids, in: listID, before: destinationID, basedOn: sortMode),
            sortedBy: sortMode
        )
    }

    func replaceAll(with replacement: [Snip]) throws {
        _ = try perform(.replaceAll(replacement), sortedBy: .manual)
    }

    func removeUnreferencedAttachments(
        currentSnips: [Snip],
        keepingAdditional relativePaths: Set<String>
    ) {
        let livePaths = Set(currentSnips.flatMap(\.attachments).map(\.relativePath))
        Self.removeUnreferencedAttachmentDirectories(
            at: attachmentRootURL,
            keeping: relativePaths.union(livePaths)
        )
    }

    private static func removeUnreferencedAttachmentDirectories(
        at attachmentRootURL: URL,
        keeping relativePaths: Set<String>
    ) {
        let keptDirectories = Set(relativePaths.compactMap { path in
            path.split(separator: "/", maxSplits: 1).first.map(String.init)
        })
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: attachmentRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directory in directories where !keptDirectories.contains(directory.lastPathComponent) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func persistMutation<Result>(_ mutation: () -> Result) throws -> Result {
        let previousSnips = snips
        let previousLists = lists
        let previousSeenRequestIDs = seenRequestIDs
        rememberCurrentAttachments()
        let result = mutation()
        rememberCurrentAttachments()
        do {
            try persist()
            return result
        } catch {
            snips = previousSnips
            lists = previousLists
            seenRequestIDs = previousSeenRequestIDs
            throw error
        }
    }

    private func rememberCurrentAttachments() {
        knownAttachmentPaths.merge(
            snips.flatMap(\.attachments).map { ($0.id, $0.relativePath) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private func persist() throws {
        try ensureAvailable()
        try Self.write(
            snips: snips,
            lists: lists,
            seenRequestIDs: seenRequestIDs,
            to: fileURL
        )
    }

    private static func write(
        snips: [Snip],
        lists: [SnipList],
        seenRequestIDs: Set<UUID>,
        to fileURL: URL
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            Document(
                version: Self.currentVersion,
                snips: snips,
                lists: lists,
                seenRequestIDs: seenRequestIDs
            )
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func ensureAvailable() throws {
        guard isAvailable else { throw SnipLibraryError.storeUnavailable }
    }

    private struct PreparedAttachments {
        var attachments: [SnipAttachment]
        var createdDirectories: [URL]
    }

    private func prepareAttachments(
        _ sourceURLs: [URL],
        currentSnips: [Snip]
    ) throws -> PreparedAttachments {
        guard !sourceURLs.isEmpty else {
            return PreparedAttachments(attachments: [], createdDirectories: [])
        }
        let existingByPath = Dictionary(
            currentSnips.flatMap(\.attachments).map { attachment in
                (attachmentURL(for: attachment).standardizedFileURL.path, attachment)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var prepared: [SnipAttachment] = []
        var createdDirectories: [URL] = []
        do {
            for sourceURL in sourceURLs {
                if let existing = existingByPath[sourceURL.standardizedFileURL.path] {
                    if !prepared.contains(where: { $0.id == existing.id }) {
                        prepared.append(existing)
                    }
                    continue
                }
                let didAccess = sourceURL.startAccessingSecurityScopedResource()
                defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { throw SnipLibraryError.attachmentCopyFailed }
                let id = UUID()
                let relativePath = "\(id.uuidString)/\(sourceURL.lastPathComponent)"
                let destination = attachmentRootURL.appendingPathComponent(relativePath, isDirectory: false)
                let destinationDirectory = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: destinationDirectory,
                    withIntermediateDirectories: true
                )
                createdDirectories.append(destinationDirectory)
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                let values = try destination.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                let attachment = SnipAttachment(
                    id: id,
                    fileName: sourceURL.lastPathComponent,
                    relativePath: relativePath,
                    contentType: values.contentType?.identifier,
                    byteCount: Int64(values.fileSize ?? 0)
                )
                prepared.append(attachment)
            }
            return PreparedAttachments(
                attachments: prepared,
                createdDirectories: createdDirectories
            )
        } catch {
            removeAttachmentDirectories(createdDirectories)
            throw error
        }
    }

    nonisolated func attachmentURL(for attachment: SnipAttachment) -> URL {
        attachmentRootURL.appendingPathComponent(attachment.relativePath, isDirectory: false)
    }

    private func removeAttachmentDirectories(_ directories: [URL]) {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    private static func validatedLists(
        _ stored: [SnipList],
        snips: [Snip]
    ) -> [SnipList] {
        var result = stored
        guard Set(result.map(\.id)).count == result.count,
              Set(result.map { $0.name.lowercased() }).count == result.count,
              result.contains(where: { $0.id == SnipList.inboxID }),
              Set(snips.map(\.listID)).isSubset(of: Set(result.map(\.id))) else {
            return []
        }
        result.removeAll { $0.id == SnipList.inboxID }
        result.insert(.inbox, at: 0)
        for index in result.indices { result[index].position = index }
        return result
    }
}
