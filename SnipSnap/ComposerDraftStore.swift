import Foundation

struct ComposerDraft: Equatable {
    var text = ""
    var attachments: [URL] = []
}

@MainActor
final class ComposerDraftStore {
    struct SaveSnapshot {
        let listID: UUID
        let draft: ComposerDraft
    }

    private let defaults: UserDefaults
    private let textDefaultsKey: String
    private var textByList: [String: String]
    private var textWriteTask: Task<Void, Never>?
    private var attachmentsByList: [UUID: [URL]] = [:]
    private var temporaryAttachments: Set<URL> = []
    private var inFlightCounts: [URL: Int] = [:]

    init(defaults: UserDefaults = .standard, textDefaultsKey: String) {
        self.defaults = defaults
        self.textDefaultsKey = textDefaultsKey
        textByList = defaults.dictionary(forKey: textDefaultsKey) as? [String: String] ?? [:]
    }

    deinit {
        textWriteTask?.cancel()
        for url in temporaryAttachments {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func draft(for listID: UUID) -> ComposerDraft {
        return ComposerDraft(
            text: textByList[listID.uuidString] ?? "",
            attachments: attachmentsByList[listID] ?? []
        )
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

    func addTemporary(_ url: URL, to listID: UUID) {
        temporaryAttachments.insert(url)
        add([url], to: listID)
    }

    func stageScreenCapture() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip Snap Capture \(UUID().uuidString).png")
        temporaryAttachments.insert(url)
        return url
    }

    func finishScreenCapture(_ url: URL, in listID: UUID, succeeded: Bool) {
        guard succeeded, FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: url)
            temporaryAttachments.remove(url)
            return
        }
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

    func beginSave(listID: UUID) -> SaveSnapshot {
        let draft = draft(for: listID)
        for url in draft.attachments where temporaryAttachments.contains(url) {
            inFlightCounts[url, default: 0] += 1
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

        for url in snapshot.draft.attachments where inFlightCounts[url] != nil {
            let remaining = (inFlightCounts[url] ?? 1) - 1
            if remaining > 0 {
                inFlightCounts[url] = remaining
            } else {
                inFlightCounts.removeValue(forKey: url)
            }
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
        for url in urls
        where temporaryAttachments.contains(url)
            && inFlightCounts[url] == nil
            && !draftedURLs.contains(url) {
            try? FileManager.default.removeItem(at: url)
            temporaryAttachments.remove(url)
        }
    }
}
