import Foundation
import UniformTypeIdentifiers

enum SnipRepositoryError: Error, Equatable, LocalizedError {
    case emptyContent
    case snipNotFound
    case invalidStore
    case storeUnavailable
    case requiresMultipleSnips
    case snipChanged
    case duplicateList
    case invalidList
    case attachmentCopyFailed

    var errorDescription: String? {
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

enum SnipAddOutcome: Equatable {
    case added(UUID)
    case duplicate
}

actor SnipRepository {
    private struct Document: Codable {
        let version: Int
        var snips: [Snip]
        var lists: [SnipList]

        private enum CodingKeys: String, CodingKey {
            case version
            case snips
            case lists
            case legacyItems = "items"
            case legacySections = "sections"
        }

        init(version: Int, snips: [Snip], lists: [SnipList]) {
            self.version = version
            self.snips = snips
            self.lists = lists
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            snips = try container.decodeIfPresent([Snip].self, forKey: .snips)
                ?? container.decode([Snip].self, forKey: .legacyItems)
            lists = try container.decodeIfPresent([SnipList].self, forKey: .lists)
                ?? container.decode([SnipList].self, forKey: .legacySections)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(snips, forKey: .snips)
            try container.encode(lists, forKey: .lists)
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
    // Keep deleted request IDs for this repository lifetime so delayed retries
    // cannot recreate a snip the user already removed.
    private var seenRequestIDs: Set<UUID>

    init(fileURL: URL = SnipRepository.defaultStoreURL()) throws {
        try Self.moveLegacyStoreIfNeeded(to: fileURL)
        self.fileURL = fileURL
        attachmentRootURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Attachments", isDirectory: true)
        isAvailable = true

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            snips = []
            lists = [.inbox]
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
                throw SnipRepositoryError.invalidStore
            }
            snips = document.snips
            lists = Self.validatedLists(document.lists, snips: snips)
            guard !lists.isEmpty else { throw SnipRepositoryError.invalidStore }
            seenRequestIDs = Set(document.snips.map(\.requestID))
            if document.version == Self.legacyVersion {
                try Self.write(snips: snips, lists: lists, to: fileURL)
            }
        } catch let error as SnipRepositoryError {
            throw error
        } catch {
            throw SnipRepositoryError.invalidStore
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
        seenRequestIDs = []
    }

    static func openRecoveringCorruptStore(
        fileURL: URL = SnipRepository.defaultStoreURL()
    ) throws -> (repository: SnipRepository, backupURL: URL?) {
        do {
            return (try SnipRepository(fileURL: fileURL), nil)
        } catch SnipRepositoryError.invalidStore {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw SnipRepositoryError.invalidStore
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
            return (try SnipRepository(fileURL: fileURL), backupURL)
        }
    }

    static func unavailable(
        fileURL: URL = SnipRepository.defaultStoreURL()
    ) -> SnipRepository {
        SnipRepository(unavailableAt: fileURL)
    }

    static func defaultStoreURL(fileManager: FileManager = .default) -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["SNIP_SNAP_STORE_PATH"],
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: false)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
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

    func allSnips(sortMode: SnipSortMode = .chronological) -> [Snip] {
        let snipsByList = Dictionary(grouping: snips, by: \.listID)
        return allLists().flatMap { list in
            Snip.sorted(snipsByList[list.id] ?? [], by: sortMode)
        }
    }

    func allLists() -> [SnipList] {
        lists.sorted { $0.position < $1.position }
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
        try ensureAvailable()
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanContent.isEmpty || !attachmentURLs.isEmpty else { throw SnipRepositoryError.emptyContent }
        guard !seenRequestIDs.contains(requestID) else { return nil }
        guard lists.contains(where: { $0.id == listID }) else { throw SnipRepositoryError.invalidList }
        let storedContent = origin == .selection ? content : cleanContent
        let prepared = try prepareAttachments(attachmentURLs)

        let snip = Snip(
            requestID: requestID,
            createdAt: now,
            content: storedContent,
            origin: origin,
            source: source,
            listID: listID,
            manualPosition: nextTopPosition(in: listID),
            attachments: prepared.attachments
        )
        do {
            return try persistMutation {
                snips.append(snip)
                seenRequestIDs.insert(requestID)
                return snip
            }
        } catch {
            removeAttachmentDirectories(prepared.createdDirectories)
            throw error
        }
    }

    func createList(name: String, systemImage: String) throws -> SnipList {
        try ensureAvailable()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw SnipRepositoryError.invalidList }
        guard !lists.contains(where: { $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }) else {
            throw SnipRepositoryError.duplicateList
        }
        let list = SnipList(
            id: UUID(),
            name: cleanName,
            systemImage: systemImage.isEmpty ? "circle.grid.2x2.fill" : systemImage,
            position: (lists.map(\.position).max() ?? 0) + 1
        )
        return try persistMutation {
            lists.append(list)
            return list
        }
    }

    func updateList(id: UUID, name: String, systemImage: String) throws {
        try ensureAvailable()
        guard id != SnipList.inboxID,
              let index = lists.firstIndex(where: { $0.id == id }) else {
            throw SnipRepositoryError.invalidList
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw SnipRepositoryError.invalidList }
        guard !lists.contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
        }) else { throw SnipRepositoryError.duplicateList }
        try persistMutation {
            lists[index].name = cleanName
            lists[index].systemImage = systemImage
        }
    }

    func deleteList(id: UUID) throws {
        try ensureAvailable()
        guard id != SnipList.inboxID,
              let list = lists.first(where: { $0.id == id }) else {
            throw SnipRepositoryError.invalidList
        }
        let movingIDs = Snip.sorted(
            snips.filter { $0.listID == list.id },
            by: .manual
        ).map(\.id)
        let firstPosition = nextTopPosition(in: SnipList.inboxID)
            - Int64(max(0, movingIDs.count - 1))
        try persistMutation {
            lists.removeAll { $0.id == id }
            for (offset, snipID) in movingIDs.enumerated() {
                guard let index = snips.firstIndex(where: { $0.id == snipID }) else { continue }
                snips[index].listID = SnipList.inboxID
                snips[index].manualPosition = firstPosition + Int64(offset)
            }
            for index in lists.indices { lists[index].position = index }
        }
    }

    func update(
        id: UUID,
        content: String,
        attachmentURLs: [URL]? = nil,
        expectedUpdatedAt: Date? = nil,
        now: Date = Date()
    ) throws {
        try ensureAvailable()
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = snips.firstIndex(where: { $0.id == id }) else {
            throw SnipRepositoryError.snipNotFound
        }
        if let expectedUpdatedAt, snips[index].updatedAt != expectedUpdatedAt {
            throw SnipRepositoryError.snipChanged
        }
        let willHaveAttachments = attachmentURLs.map { !$0.isEmpty }
            ?? !snips[index].attachments.isEmpty
        guard !cleanContent.isEmpty || willHaveAttachments else {
            throw SnipRepositoryError.emptyContent
        }
        let prepared = try attachmentURLs.map(prepareAttachments)

        do {
            try persistMutation {
                snips[index].content = cleanContent
                if let prepared {
                    snips[index].attachments = prepared.attachments
                }
                snips[index].updatedAt = now
            }
        } catch {
            if let prepared { removeAttachmentDirectories(prepared.createdDirectories) }
            throw error
        }
    }

    func delete(ids: Set<UUID>) throws {
        try ensureAvailable()
        guard !ids.isEmpty else { return }
        try persistMutation {
            snips.removeAll { ids.contains($0.id) }
        }
    }

    func restore(snips restoredSnips: [Snip]) throws {
        try ensureAvailable()
        guard !restoredSnips.isEmpty else { return }
        let existingIDs = Set(snips.map(\.id))
        let additions = restoredSnips.filter { !existingIDs.contains($0.id) }
        guard !additions.isEmpty else { return }
        try persistMutation {
            snips.append(contentsOf: additions)
            seenRequestIDs.formUnion(additions.map(\.requestID))
        }
    }

    func restore(
        snips restoredSnips: [Snip],
        replacing snipID: UUID,
        expectedUpdatedAt: Date
    ) throws {
        try ensureAvailable()
        guard !restoredSnips.isEmpty else { return }
        guard let replacedSnip = snips.first(where: { $0.id == snipID }) else {
            throw SnipRepositoryError.snipNotFound
        }
        guard replacedSnip.updatedAt == expectedUpdatedAt else {
            throw SnipRepositoryError.snipChanged
        }
        try persistMutation {
            snips.removeAll { $0.id == snipID }
            let existingIDs = Set(snips.map(\.id))
            snips.append(contentsOf: restoredSnips.filter { !existingIDs.contains($0.id) })
            seenRequestIDs.formUnion(restoredSnips.map(\.requestID))
        }
    }

    func merge(
        ids: Set<UUID>,
        now: Date = Date()
    ) throws -> Snip {
        try ensureAvailable()
        let selectedSnips = Snip.sorted(snips.filter { ids.contains($0.id) }, by: .chronological)
        guard selectedSnips.count >= 2 else { throw SnipRepositoryError.requiresMultipleSnips }
        let listIDs = Set(selectedSnips.map(\.listID))
        let destinationListID = listIDs.count == 1 ? selectedSnips[0].listID : SnipList.inboxID
        let manualPosition: Int64
        if listIDs.count == 1 {
            manualPosition = selectedSnips.map(\.manualPosition).min() ?? 0
        } else {
            manualPosition = nextTopPosition(in: destinationListID)
        }
        var seenAttachmentIDs: Set<UUID> = []
        let mergedAttachments = selectedSnips
            .flatMap(\.attachments)
            .filter { seenAttachmentIDs.insert($0.id).inserted }
        let mergedSnip = Snip(
            createdAt: now,
            content: SnipFormatter.format(snips: selectedSnips),
            origin: .quickEntry,
            listID: destinationListID,
            manualPosition: manualPosition,
            attachments: mergedAttachments
        )
        return try persistMutation {
            snips.removeAll { ids.contains($0.id) }
            snips.append(mergedSnip)
            seenRequestIDs.insert(mergedSnip.requestID)
            return mergedSnip
        }
    }

    func setDone(ids: Set<UUID>, done: Bool) throws {
        try ensureAvailable()
        guard !ids.isEmpty else { return }
        try update(ids: ids) { snip in
            snip.isDone = done
        }
    }

    func toggleDone(id: UUID) throws {
        try ensureAvailable()
        guard let snip = snips.first(where: { $0.id == id }) else {
            throw SnipRepositoryError.snipNotFound
        }
        try setDone(ids: [id], done: !snip.isDone)
    }

    func toggleDone(ids: Set<UUID>) throws {
        try ensureAvailable()
        let selected = snips.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        try setDone(ids: ids, done: selected.contains { !$0.isDone })
    }

    func moveChronologically(ids: [UUID], to listID: UUID) throws {
        try ensureAvailable()
        guard !ids.isEmpty else { return }
        guard lists.contains(where: { $0.id == listID }) else { throw SnipRepositoryError.invalidList }
        let orderedIDs = ids.filter { id in
            snips.contains { $0.id == id && $0.listID != listID }
        }
        guard !orderedIDs.isEmpty else { return }
        try persistMutation {
            let top = nextTopPosition(in: listID, excluding: Set(orderedIDs))
                - Int64(orderedIDs.count - 1)
            for (offset, id) in orderedIDs.enumerated() {
                guard let index = snips.firstIndex(where: { $0.id == id }) else { continue }
                snips[index].listID = listID
                snips[index].manualPosition = top + Int64(offset)
            }
        }
    }

    func place(
        ids: [UUID],
        in listID: UUID,
        before destinationID: UUID?,
        basedOn sortMode: SnipSortMode = .manual
    ) throws {
        try ensureAvailable()
        guard !ids.isEmpty else { return }
        guard lists.contains(where: { $0.id == listID }) else { throw SnipRepositoryError.invalidList }
        let movingSet = Set(ids)
        let orderedMovingIDs = ids.filter { id in snips.contains { $0.id == id } }
        guard !orderedMovingIDs.isEmpty else { return }
        let sourceLists = Set(snips.filter { movingSet.contains($0.id) }.map(\.listID))

        try persistMutation {
            var destinationIDs = Snip.sorted(
                snips.filter { $0.listID == listID && !movingSet.contains($0.id) },
                by: sortMode
            ).map(\.id)
            let insertionIndex = destinationID.flatMap(destinationIDs.firstIndex) ?? destinationIDs.endIndex
            destinationIDs.insert(contentsOf: orderedMovingIDs, at: insertionIndex)
            for id in orderedMovingIDs {
                guard let index = snips.firstIndex(where: { $0.id == id }) else { continue }
                snips[index].listID = listID
            }
            reindex(listID: listID, orderedIDs: destinationIDs)
            for sourceList in sourceLists where sourceList != listID {
                reindex(listID: sourceList)
            }
        }
    }

    func replaceAll(with replacement: [Snip]) throws {
        try ensureAvailable()
        try persistMutation {
            snips = replacement
            seenRequestIDs.formUnion(replacement.map(\.requestID))
        }
    }

    func removeUnreferencedAttachments(keepingAdditional relativePaths: Set<String>) {
        let livePaths = Set(snips.flatMap(\.attachments).map(\.relativePath))
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

    private func update(
        ids: Set<UUID>,
        change: (inout Snip) -> Void
    ) throws {
        try persistMutation {
            for index in snips.indices where ids.contains(snips[index].id) {
                change(&snips[index])
                snips[index].updatedAt = Date()
            }
        }
    }

    private func persistMutation<Result>(_ mutation: () -> Result) throws -> Result {
        let previousSnips = snips
        let previousLists = lists
        let previousSeenRequestIDs = seenRequestIDs
        let result = mutation()
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

    private func persist() throws {
        try ensureAvailable()
        try Self.write(snips: snips, lists: lists, to: fileURL)
    }

    private static func write(snips: [Snip], lists: [SnipList], to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            Document(version: Self.currentVersion, snips: snips, lists: lists)
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func ensureAvailable() throws {
        guard isAvailable else { throw SnipRepositoryError.storeUnavailable }
    }

    private struct PreparedAttachments {
        var attachments: [SnipAttachment]
        var createdDirectories: [URL]
    }

    private func prepareAttachments(_ sourceURLs: [URL]) throws -> PreparedAttachments {
        guard !sourceURLs.isEmpty else {
            return PreparedAttachments(attachments: [], createdDirectories: [])
        }
        let existingByPath = Dictionary(
            snips.flatMap(\.attachments).map { attachment in
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
                      !isDirectory.boolValue else { throw SnipRepositoryError.attachmentCopyFailed }
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

    private func removeAttachmentDirectories(for attachments: [SnipAttachment]) {
        removeAttachmentDirectories(
            attachments.map { attachmentURL(for: $0).deletingLastPathComponent() }
        )
    }

    private func removeAttachmentDirectories(_ directories: [URL]) {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    private func nextTopPosition(in listID: UUID, excluding excluded: Set<UUID> = []) -> Int64 {
        let minimum = snips
            .filter { $0.listID == listID && !excluded.contains($0.id) }
            .map(\.manualPosition)
            .min() ?? 1
        return minimum - 1
    }

    private func reindex(listID: UUID, orderedIDs: [UUID]? = nil) {
        let ids = orderedIDs ?? Snip.sorted(
            snips.filter { $0.listID == listID },
            by: .manual
        ).map(\.id)
        for (position, id) in ids.enumerated() {
            guard let index = snips.firstIndex(where: { $0.id == id }) else { continue }
            snips[index].manualPosition = Int64(position)
        }
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
