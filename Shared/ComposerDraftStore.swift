import Foundation
import SnipSnapCore

struct ComposerDraft: Equatable {
    var text = ""
    var attachments: [URL] = []
}

@MainActor
final class ComposerDraftStore {
    static let unattributedLegacyScope = "legacy-unattributed"
    struct SaveSnapshot {
        let listID: UUID
        let draft: ComposerDraft
    }

    private let defaults: UserDefaults
    private let baseTextDefaultsKey: String
    private var textDefaultsKey: String
    private(set) var scope: String
    private let temporaryRootDirectory: URL?
    private var textByList: [String: String]
    private var textWriteTask: Task<Void, Never>?
    private var attachmentsByList: [UUID: [URL]] = [:]
    private var attachmentsByScope: [String: [UUID: [URL]]] = [:]
    /// Files the store owns, each with the number of saves holding it. A file is removed once no
    /// draft references it and no save holds it.
    private var temporaryFiles: [URL: Int] = [:]

    init(
        defaults: UserDefaults = .standard,
        textDefaultsKey: String,
        scope: String = "local",
        temporaryRootDirectory: URL? = nil
    ) {
        self.defaults = defaults
        baseTextDefaultsKey = textDefaultsKey
        self.scope = scope
        self.textDefaultsKey = Self.scopedTextKey(textDefaultsKey, scope: scope)
        self.temporaryRootDirectory = temporaryRootDirectory
        let migrationKey = textDefaultsKey + ".scopesInitialized"
        if !defaults.bool(forKey: migrationKey) {
            let legacy = defaults.dictionary(forKey: textDefaultsKey) as? [String: String] ?? [:]
            if !legacy.isEmpty {
                defaults.set(
                    legacy,
                    forKey: Self.scopedTextKey(
                        textDefaultsKey, scope: Self.unattributedLegacyScope
                    )
                )
            }
            defaults.set(true, forKey: migrationKey)
        }
        textByList = defaults.dictionary(forKey: self.textDefaultsKey) as? [String: String] ?? [:]
    }

    private static func scopedTextKey(_ base: String, scope: String) -> String {
        base + ".scope." + Data(scope.utf8).base64EncodedString()
    }

    func switchScope(to newScope: String) {
        guard scope != newScope else { return }
        flushText()
        attachmentsByScope[scope] = attachmentsByList
        scope = newScope
        textDefaultsKey = Self.scopedTextKey(baseTextDefaultsKey, scope: newScope)
        textByList = defaults.dictionary(forKey: textDefaultsKey) as? [String: String] ?? [:]
        attachmentsByList = attachmentsByScope.removeValue(forKey: newScope) ?? [:]
    }

    struct PreparedScope {
        fileprivate let previousScope: String
        fileprivate let previousText: [String: String]
        fileprivate let previousAttachments: [UUID: [URL]]
        fileprivate let previousScopes: [String: [UUID: [URL]]]
        fileprivate let scope: String
        fileprivate let key: String
        fileprivate let text: [String: String]
        fileprivate let attachments: [UUID: [URL]]
    }

    struct RetiredScopeWrite {
        fileprivate let key: String
        fileprivate let text: [String: String]
        fileprivate let pending: Task<Void, Never>?
    }

    func prepareScope(_ newScope: String) -> PreparedScope {
        let key = Self.scopedTextKey(baseTextDefaultsKey, scope: newScope)
        return PreparedScope(previousScope: scope, previousText: textByList,
            previousAttachments: attachmentsByList, previousScopes: attachmentsByScope,
            scope: newScope, key: key,
            text: newScope == scope ? textByList : defaults.dictionary(forKey: key) as? [String: String] ?? [:],
            attachments: newScope == scope ? attachmentsByList : attachmentsByScope[newScope] ?? [:])
    }

    func validatePreparedScope(_ prepared: PreparedScope) throws {
        guard scope == prepared.previousScope, textByList == prepared.previousText,
              attachmentsByList == prepared.previousAttachments,
              attachmentsByScope == prepared.previousScopes else { throw SnipLibraryError.importChanged }
    }

    func installPreparedScope(_ prepared: PreparedScope) throws -> RetiredScopeWrite? {
        try validatePreparedScope(prepared)
        return installValidatedScope(prepared)
    }

    /// MainActor state must not change between validation and this callback-free assignment.
    func installValidatedScope(_ prepared: PreparedScope) -> RetiredScopeWrite? {
        guard prepared.scope != scope else { return nil }
        let write = RetiredScopeWrite(key: textDefaultsKey, text: textByList, pending: textWriteTask)
        textWriteTask = nil
        attachmentsByScope[scope] = attachmentsByList
        scope = prepared.scope
        textDefaultsKey = prepared.key
        textByList = prepared.text
        attachmentsByList = prepared.attachments
        attachmentsByScope.removeValue(forKey: scope)
        return write
    }

    func finishScopeWrite(_ write: RetiredScopeWrite?) {
        guard let write else { return }
        write.pending?.cancel()
        defaults.set(write.text, forKey: write.key)
    }

    deinit {
        textWriteTask?.cancel()
        if let temporaryRootDirectory {
            try? FileManager.default.removeItem(at: temporaryRootDirectory)
        } else {
            for url in temporaryFiles.keys {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func draft(for listID: UUID) -> ComposerDraft {
        ComposerDraft(
            text: textByList[listID.uuidString] ?? "",
            attachments: attachmentsByList[listID] ?? []
        )
    }

    func draftListIDs() -> Set<UUID> {
        Set(textByList.keys.compactMap(UUID.init(uuidString:)))
            .union(attachmentsByList.keys)
    }

    func unattributedLegacyDrafts() -> [(id: UUID, text: String)] {
        let key = Self.scopedTextKey(
            baseTextDefaultsKey, scope: Self.unattributedLegacyScope
        )
        let saved = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return saved.compactMap { rawID, text in
            guard let id = UUID(uuidString: rawID), !text.isEmpty else { return nil }
            return (id: id, text: text)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func moveUnattributedLegacyDraftToInbox(_ id: UUID) {
        let key = Self.scopedTextKey(
            baseTextDefaultsKey, scope: Self.unattributedLegacyScope
        )
        var saved = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard let text = saved[id.uuidString], !text.isEmpty else { return }
        let current = draft(for: SnipList.inboxID).text
        setText(current.isEmpty ? text : current + "\n\n" + text, for: SnipList.inboxID)
        flushText()
        saved.removeValue(forKey: id.uuidString)
        defaults.set(saved, forKey: key)
    }

    func setText(_ text: String, for listID: UUID) {
        if text.isEmpty {
            textByList.removeValue(forKey: listID.uuidString)
        } else {
            textByList[listID.uuidString] = text
        }
        scheduleTextWrite()
    }

    func flushText() {
        textWriteTask?.cancel()
        textWriteTask = nil
        defaults.set(textByList, forKey: textDefaultsKey)
    }

    func add(_ urls: [URL], to listID: UUID) {
        var attachments = draft(for: listID).attachments
        attachments.append(contentsOf: urls.filter { !attachments.contains($0) })
        set(attachments, for: listID)
    }

    func replaceAttachments(_ urls: [URL], for listID: UUID) {
        let previous = Set(draft(for: listID).attachments)
        set(urls, for: listID)
        removeTemporaryFilesIfUnused(previous.subtracting(urls))
    }

    func addTemporary(_ url: URL, to listID: UUID) {
        if temporaryFiles[url] == nil { temporaryFiles[url] = 0 }
        add([url], to: listID)
    }

    func remove(_ url: URL, from listID: UUID) {
        var attachments = draft(for: listID).attachments
        attachments.removeAll { $0 == url }
        set(attachments, for: listID)
        removeTemporaryFilesIfUnused([url])
    }

    func clear(listID: UUID) {
        let discarded = Set(draft(for: listID).attachments)
        setText("", for: listID)
        attachmentsByList.removeValue(forKey: listID)
        removeTemporaryFilesIfUnused(discarded)
    }

    func moveDraft(from sourceID: UUID, to destinationID: UUID) {
        guard sourceID != destinationID else { return }
        let source = draft(for: sourceID)
        guard !source.text.isEmpty || !source.attachments.isEmpty else { return }
        let destination = draft(for: destinationID)
        if !source.text.isEmpty {
            let separator = destination.text.isEmpty ? "" : "\n\n"
            setText(destination.text + separator + source.text, for: destinationID)
        }
        add(source.attachments, to: destinationID)
        clear(listID: sourceID)
    }

    func beginSave(listID: UUID, content: String? = nil) -> SaveSnapshot {
        var draft = draft(for: listID)
        if let content { draft.text = content }
        for url in draft.attachments {
            temporaryFiles[url]? += 1
        }
        return SaveSnapshot(listID: listID, draft: draft)
    }

    func finishSave(_ snapshot: SaveSnapshot, saved: Bool) {
        if saved {
            var current = draft(for: snapshot.listID)
            current.attachments.removeAll { snapshot.draft.attachments.contains($0) }
            set(current.attachments, for: snapshot.listID)
            if current.text == snapshot.draft.text {
                setText("", for: snapshot.listID)
            }
        }

        for url in snapshot.draft.attachments {
            if let holds = temporaryFiles[url], holds > 0 { temporaryFiles[url] = holds - 1 }
        }
        removeTemporaryFilesIfUnused(Set(snapshot.draft.attachments))
    }

    private func set(_ attachments: [URL], for listID: UUID) {
        if attachments.isEmpty {
            attachmentsByList.removeValue(forKey: listID)
        } else {
            attachmentsByList[listID] = attachments
        }
    }

    private func scheduleTextWrite() {
        textWriteTask?.cancel()
        textWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.flushText()
        }
    }

    private func removeTemporaryFilesIfUnused(_ urls: Set<URL>) {
        let draftedURLs = Set(attachmentsByList.values.flatMap { $0 })
            .union(attachmentsByScope.values.flatMap { $0.values.flatMap { $0 } })
        for url in urls where temporaryFiles[url] == 0 && !draftedURLs.contains(url) {
            try? FileManager.default.removeItem(at: url)
            temporaryFiles.removeValue(forKey: url)
        }
    }
}
