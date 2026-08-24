import Foundation
import UniformTypeIdentifiers

enum RepositoryError: Error, Equatable, LocalizedError {
    case emptyContent
    case itemNotFound
    case invalidStore
    case storeUnavailable
    case requiresMultipleItems
    case itemChanged
    case duplicateSection
    case invalidSection
    case attachmentCopyFailed

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            "There is nothing to save."
        case .itemNotFound:
            "That clip no longer exists."
        case .invalidStore:
            "Snip Snap could not read its saved clips."
        case .storeUnavailable:
            "Snip Snap cannot save changes until its clip store is available."
        case .requiresMultipleItems:
            "Select at least two clips to merge."
        case .itemChanged:
            "This clip changed in another window. Copy your edits, reopen it, and try again."
        case .duplicateSection:
            "A section with that name already exists."
        case .invalidSection:
            "That section is not available."
        case .attachmentCopyFailed:
            "Snip Snap could not copy one of the files."
        }
    }
}

enum AddOutcome: Equatable {
    case added(UUID)
    case duplicate
}

actor ItemRepository {
    private struct Document: Codable {
        let version: Int
        var items: [CaptureItem]
        var sections: [SnipSnapSection]
    }

    static let currentVersion = 4

    private let fileURL: URL
    nonisolated let attachmentRootURL: URL
    private let isAvailable: Bool
    private var items: [CaptureItem]
    private var sections: [SnipSnapSection]
    // Keep deleted request IDs for this repository lifetime so delayed retries
    // cannot recreate an item the user already removed.
    private var seenRequestIDs: Set<UUID>

    init(fileURL: URL = ItemRepository.defaultStoreURL()) throws {
        self.fileURL = fileURL
        attachmentRootURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Attachments", isDirectory: true)
        isAvailable = true

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            items = []
            sections = [.inbox]
            seenRequestIDs = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: data)
            guard document.version == Self.currentVersion else {
                throw RepositoryError.invalidStore
            }
            items = document.items
            sections = Self.validatedSections(document.sections, items: items)
            guard !sections.isEmpty else { throw RepositoryError.invalidStore }
            seenRequestIDs = Set(document.items.map(\.requestID))
        } catch let error as RepositoryError {
            throw error
        } catch {
            throw RepositoryError.invalidStore
        }
        Self.removeUnreferencedAttachmentDirectories(
            at: attachmentRootURL,
            keeping: Set(items.flatMap(\.attachments).map(\.relativePath))
        )
    }

    private init(unavailableAt fileURL: URL) {
        self.fileURL = fileURL
        attachmentRootURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Attachments", isDirectory: true)
        isAvailable = false
        items = []
        sections = [.inbox]
        seenRequestIDs = []
    }

    static func openRecoveringCorruptStore(
        fileURL: URL = ItemRepository.defaultStoreURL()
    ) throws -> (repository: ItemRepository, backupURL: URL?) {
        do {
            return (try ItemRepository(fileURL: fileURL), nil)
        } catch RepositoryError.invalidStore {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw RepositoryError.invalidStore
            }
            let recoveryID = UUID().uuidString
            let parentURL = fileURL.deletingLastPathComponent()
            let backupURL = parentURL
                .appendingPathComponent(
                    "items.corrupt-\(recoveryID).json",
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
            return (try ItemRepository(fileURL: fileURL), backupURL)
        }
    }

    static func unavailable(
        fileURL: URL = ItemRepository.defaultStoreURL()
    ) -> ItemRepository {
        ItemRepository(unavailableAt: fileURL)
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
            .appendingPathComponent("items.json", isDirectory: false)
    }

    func allItems(sortMode: ClipSortMode = .chronological) -> [CaptureItem] {
        let itemsBySection = Dictionary(grouping: items, by: \.sectionID)
        return allSections().flatMap { section in
            CaptureItem.sorted(itemsBySection[section.id] ?? [], by: sortMode)
        }
    }

    func allSections() -> [SnipSnapSection] {
        sections.sorted { $0.position < $1.position }
    }

    @discardableResult
    func add(
        content: String,
        origin: CaptureOrigin,
        source: CaptureSource? = nil,
        sectionID: UUID = SnipSnapSection.inboxID,
        attachmentURLs: [URL] = [],
        requestID: UUID = UUID(),
        now: Date = Date()
    ) throws -> CaptureItem? {
        try ensureAvailable()
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanContent.isEmpty || !attachmentURLs.isEmpty else { throw RepositoryError.emptyContent }
        guard !seenRequestIDs.contains(requestID) else { return nil }
        guard sections.contains(where: { $0.id == sectionID }) else { throw RepositoryError.invalidSection }
        let storedContent = origin == .selection ? content : cleanContent
        let prepared = try prepareAttachments(attachmentURLs)

        let item = CaptureItem(
            requestID: requestID,
            createdAt: now,
            content: storedContent,
            origin: origin,
            source: source,
            sectionID: sectionID,
            manualPosition: nextTopPosition(in: sectionID),
            attachments: prepared.attachments
        )
        do {
            return try persistMutation {
                items.append(item)
                seenRequestIDs.insert(requestID)
                return item
            }
        } catch {
            removeAttachmentDirectories(prepared.createdDirectories)
            throw error
        }
    }

    func createSection(name: String, systemImage: String) throws -> SnipSnapSection {
        try ensureAvailable()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw RepositoryError.invalidSection }
        guard !sections.contains(where: { $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }) else {
            throw RepositoryError.duplicateSection
        }
        let section = SnipSnapSection(
            id: UUID(),
            name: cleanName,
            systemImage: systemImage.isEmpty ? "circle.grid.2x2.fill" : systemImage,
            position: (sections.map(\.position).max() ?? 0) + 1
        )
        return try persistMutation {
            sections.append(section)
            return section
        }
    }

    func updateSection(id: UUID, name: String, systemImage: String) throws {
        try ensureAvailable()
        guard id != SnipSnapSection.inboxID,
              let index = sections.firstIndex(where: { $0.id == id }) else {
            throw RepositoryError.invalidSection
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw RepositoryError.invalidSection }
        guard !sections.contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
        }) else { throw RepositoryError.duplicateSection }
        try persistMutation {
            sections[index].name = cleanName
            sections[index].systemImage = systemImage
        }
    }

    func deleteSection(id: UUID) throws {
        try ensureAvailable()
        guard id != SnipSnapSection.inboxID,
              let section = sections.first(where: { $0.id == id }) else {
            throw RepositoryError.invalidSection
        }
        let movingIDs = CaptureItem.sorted(
            items.filter { $0.sectionID == section.id },
            by: .manual
        ).map(\.id)
        let firstPosition = nextTopPosition(in: SnipSnapSection.inboxID)
            - Int64(max(0, movingIDs.count - 1))
        try persistMutation {
            sections.removeAll { $0.id == id }
            for (offset, itemID) in movingIDs.enumerated() {
                guard let index = items.firstIndex(where: { $0.id == itemID }) else { continue }
                items[index].sectionID = SnipSnapSection.inboxID
                items[index].manualPosition = firstPosition + Int64(offset)
            }
            for index in sections.indices { sections[index].position = index }
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
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw RepositoryError.itemNotFound
        }
        if let expectedUpdatedAt, items[index].updatedAt != expectedUpdatedAt {
            throw RepositoryError.itemChanged
        }
        let willHaveAttachments = attachmentURLs.map { !$0.isEmpty }
            ?? !items[index].attachments.isEmpty
        guard !cleanContent.isEmpty || willHaveAttachments else {
            throw RepositoryError.emptyContent
        }
        let prepared = try attachmentURLs.map(prepareAttachments)

        do {
            try persistMutation {
                items[index].content = cleanContent
                if let prepared {
                    items[index].attachments = prepared.attachments
                }
                items[index].updatedAt = now
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
            items.removeAll { ids.contains($0.id) }
        }
    }

    func restore(items restoredItems: [CaptureItem]) throws {
        try ensureAvailable()
        guard !restoredItems.isEmpty else { return }
        let existingIDs = Set(items.map(\.id))
        let additions = restoredItems.filter { !existingIDs.contains($0.id) }
        guard !additions.isEmpty else { return }
        try persistMutation {
            items.append(contentsOf: additions)
            seenRequestIDs.formUnion(additions.map(\.requestID))
        }
    }

    func restore(
        items restoredItems: [CaptureItem],
        replacing itemID: UUID,
        expectedUpdatedAt: Date
    ) throws {
        try ensureAvailable()
        guard !restoredItems.isEmpty else { return }
        guard let replacedItem = items.first(where: { $0.id == itemID }) else {
            throw RepositoryError.itemNotFound
        }
        guard replacedItem.updatedAt == expectedUpdatedAt else {
            throw RepositoryError.itemChanged
        }
        try persistMutation {
            items.removeAll { $0.id == itemID }
            let existingIDs = Set(items.map(\.id))
            items.append(contentsOf: restoredItems.filter { !existingIDs.contains($0.id) })
            seenRequestIDs.formUnion(restoredItems.map(\.requestID))
        }
    }

    func merge(
        ids: Set<UUID>,
        now: Date = Date()
    ) throws -> CaptureItem {
        try ensureAvailable()
        let selectedItems = CaptureItem.sorted(items.filter { ids.contains($0.id) }, by: .chronological)
        guard selectedItems.count >= 2 else { throw RepositoryError.requiresMultipleItems }
        let sectionIDs = Set(selectedItems.map(\.sectionID))
        let destinationSectionID = sectionIDs.count == 1 ? selectedItems[0].sectionID : SnipSnapSection.inboxID
        let manualPosition: Int64
        if sectionIDs.count == 1 {
            manualPosition = selectedItems.map(\.manualPosition).min() ?? 0
        } else {
            manualPosition = nextTopPosition(in: destinationSectionID)
        }
        var seenAttachmentIDs: Set<UUID> = []
        let mergedAttachments = selectedItems
            .flatMap(\.attachments)
            .filter { seenAttachmentIDs.insert($0.id).inserted }
        let mergedItem = CaptureItem(
            createdAt: now,
            content: CopyFormatter.format(items: selectedItems),
            origin: .quickEntry,
            sectionID: destinationSectionID,
            manualPosition: manualPosition,
            attachments: mergedAttachments
        )
        return try persistMutation {
            items.removeAll { ids.contains($0.id) }
            items.append(mergedItem)
            seenRequestIDs.insert(mergedItem.requestID)
            return mergedItem
        }
    }

    func setDone(ids: Set<UUID>, done: Bool) throws {
        try ensureAvailable()
        guard !ids.isEmpty else { return }
        try update(ids: ids) { item in
            item.isDone = done
        }
    }

    func toggleDone(id: UUID) throws {
        try ensureAvailable()
        guard let item = items.first(where: { $0.id == id }) else {
            throw RepositoryError.itemNotFound
        }
        try setDone(ids: [id], done: !item.isDone)
    }

    func toggleDone(ids: Set<UUID>) throws {
        try ensureAvailable()
        let selected = items.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        try setDone(ids: ids, done: selected.contains { !$0.isDone })
    }

    func moveChronologically(ids: [UUID], to sectionID: UUID) throws {
        try ensureAvailable()
        guard !ids.isEmpty else { return }
        guard sections.contains(where: { $0.id == sectionID }) else { throw RepositoryError.invalidSection }
        let orderedIDs = ids.filter { id in
            items.contains { $0.id == id && $0.sectionID != sectionID }
        }
        guard !orderedIDs.isEmpty else { return }
        try persistMutation {
            let top = nextTopPosition(in: sectionID, excluding: Set(orderedIDs))
                - Int64(orderedIDs.count - 1)
            for (offset, id) in orderedIDs.enumerated() {
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                items[index].sectionID = sectionID
                items[index].manualPosition = top + Int64(offset)
            }
        }
    }

    func place(
        ids: [UUID],
        in sectionID: UUID,
        before destinationID: UUID?,
        basedOn sortMode: ClipSortMode = .manual
    ) throws {
        try ensureAvailable()
        guard !ids.isEmpty else { return }
        guard sections.contains(where: { $0.id == sectionID }) else { throw RepositoryError.invalidSection }
        let movingSet = Set(ids)
        let orderedMovingIDs = ids.filter { id in items.contains { $0.id == id } }
        guard !orderedMovingIDs.isEmpty else { return }
        let sourceSections = Set(items.filter { movingSet.contains($0.id) }.map(\.sectionID))

        try persistMutation {
            var destinationIDs = CaptureItem.sorted(
                items.filter { $0.sectionID == sectionID && !movingSet.contains($0.id) },
                by: sortMode
            ).map(\.id)
            let insertionIndex = destinationID.flatMap(destinationIDs.firstIndex) ?? destinationIDs.endIndex
            destinationIDs.insert(contentsOf: orderedMovingIDs, at: insertionIndex)
            for id in orderedMovingIDs {
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                items[index].sectionID = sectionID
            }
            reindex(sectionID: sectionID, orderedIDs: destinationIDs)
            for sourceSection in sourceSections where sourceSection != sectionID {
                reindex(sectionID: sourceSection)
            }
        }
    }

    func replaceAll(with replacement: [CaptureItem]) throws {
        try ensureAvailable()
        try persistMutation {
            items = replacement
            seenRequestIDs.formUnion(replacement.map(\.requestID))
        }
    }

    func removeUnreferencedAttachments(keepingAdditional relativePaths: Set<String>) {
        let livePaths = Set(items.flatMap(\.attachments).map(\.relativePath))
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
        change: (inout CaptureItem) -> Void
    ) throws {
        try persistMutation {
            for index in items.indices where ids.contains(items[index].id) {
                change(&items[index])
                items[index].updatedAt = Date()
            }
        }
    }

    private func persistMutation<Result>(_ mutation: () -> Result) throws -> Result {
        let previousItems = items
        let previousSections = sections
        let previousSeenRequestIDs = seenRequestIDs
        let result = mutation()
        do {
            try persist()
            return result
        } catch {
            items = previousItems
            sections = previousSections
            seenRequestIDs = previousSeenRequestIDs
            throw error
        }
    }

    private func persist() throws {
        try ensureAvailable()
        try Self.write(items: items, sections: sections, to: fileURL)
    }

    private static func write(items: [CaptureItem], sections: [SnipSnapSection], to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            Document(version: Self.currentVersion, items: items, sections: sections)
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func ensureAvailable() throws {
        guard isAvailable else { throw RepositoryError.storeUnavailable }
    }

    private struct PreparedAttachments {
        var attachments: [ClipAttachment]
        var createdDirectories: [URL]
    }

    private func prepareAttachments(_ sourceURLs: [URL]) throws -> PreparedAttachments {
        guard !sourceURLs.isEmpty else {
            return PreparedAttachments(attachments: [], createdDirectories: [])
        }
        let existingByPath = Dictionary(
            items.flatMap(\.attachments).map { attachment in
                (attachmentURL(for: attachment).standardizedFileURL.path, attachment)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var prepared: [ClipAttachment] = []
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
                      !isDirectory.boolValue else { throw RepositoryError.attachmentCopyFailed }
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
                let attachment = ClipAttachment(
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

    nonisolated func attachmentURL(for attachment: ClipAttachment) -> URL {
        attachmentRootURL.appendingPathComponent(attachment.relativePath, isDirectory: false)
    }

    private func removeAttachmentDirectories(for attachments: [ClipAttachment]) {
        removeAttachmentDirectories(
            attachments.map { attachmentURL(for: $0).deletingLastPathComponent() }
        )
    }

    private func removeAttachmentDirectories(_ directories: [URL]) {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    private func nextTopPosition(in sectionID: UUID, excluding excluded: Set<UUID> = []) -> Int64 {
        let minimum = items
            .filter { $0.sectionID == sectionID && !excluded.contains($0.id) }
            .map(\.manualPosition)
            .min() ?? 1
        return minimum - 1
    }

    private func reindex(sectionID: UUID, orderedIDs: [UUID]? = nil) {
        let ids = orderedIDs ?? CaptureItem.sorted(
            items.filter { $0.sectionID == sectionID },
            by: .manual
        ).map(\.id)
        for (position, id) in ids.enumerated() {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            items[index].manualPosition = Int64(position)
        }
    }

    private static func validatedSections(
        _ stored: [SnipSnapSection],
        items: [CaptureItem]
    ) -> [SnipSnapSection] {
        var result = stored
        guard Set(result.map(\.id)).count == result.count,
              Set(result.map { $0.name.lowercased() }).count == result.count,
              result.contains(where: { $0.id == SnipSnapSection.inboxID }),
              Set(items.map(\.sectionID)).isSubset(of: Set(result.map(\.id))) else {
            return []
        }
        result.removeAll { $0.id == SnipSnapSection.inboxID }
        result.insert(.inbox, at: 0)
        for index in result.indices { result[index].position = index }
        return result
    }
}
