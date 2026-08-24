import Foundation

struct ComposerDraft: Equatable {
    var text = ""
    var attachments: [URL] = []
}

@MainActor
final class ComposerDraftStore {
    struct SaveSnapshot {
        let sectionID: UUID
        let draft: ComposerDraft
    }

    private let defaults: UserDefaults
    private let textDefaultsKey: String
    private var textBySection: [String: String]
    private var textWriteTask: Task<Void, Never>?
    private var attachmentsBySection: [UUID: [URL]] = [:]
    private var temporaryAttachments: Set<URL> = []
    private var inFlightCounts: [URL: Int] = [:]

    init(defaults: UserDefaults = .standard, textDefaultsKey: String) {
        self.defaults = defaults
        self.textDefaultsKey = textDefaultsKey
        textBySection = defaults.dictionary(forKey: textDefaultsKey) as? [String: String] ?? [:]
    }

    deinit {
        textWriteTask?.cancel()
        for url in temporaryAttachments {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func draft(for sectionID: UUID) -> ComposerDraft {
        return ComposerDraft(
            text: textBySection[sectionID.uuidString] ?? "",
            attachments: attachmentsBySection[sectionID] ?? []
        )
    }

    func setText(_ text: String, for sectionID: UUID) {
        if text.isEmpty {
            textBySection.removeValue(forKey: sectionID.uuidString)
        } else {
            textBySection[sectionID.uuidString] = text
        }
        scheduleTextWrite()
    }

    func flushText() {
        textWriteTask?.cancel()
        textWriteTask = nil
        defaults.set(textBySection, forKey: textDefaultsKey)
    }

    func add(_ urls: [URL], to sectionID: UUID) {
        var attachments = draft(for: sectionID).attachments
        attachments.append(contentsOf: urls.filter { !attachments.contains($0) })
        set(attachments, for: sectionID)
    }

    func addTemporary(_ url: URL, to sectionID: UUID) {
        temporaryAttachments.insert(url)
        add([url], to: sectionID)
    }

    func stageScreenCapture() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip Snap Capture \(UUID().uuidString).png")
        temporaryAttachments.insert(url)
        return url
    }

    func finishScreenCapture(_ url: URL, in sectionID: UUID, succeeded: Bool) {
        guard succeeded, FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: url)
            temporaryAttachments.remove(url)
            return
        }
        add([url], to: sectionID)
    }

    func remove(_ url: URL, from sectionID: UUID) {
        var attachments = draft(for: sectionID).attachments
        attachments.removeAll { $0 == url }
        set(attachments, for: sectionID)
        removeTemporaryFilesIfUnused([url])
    }

    func clear(sectionID: UUID) {
        let discarded = Set(draft(for: sectionID).attachments)
        setText("", for: sectionID)
        attachmentsBySection.removeValue(forKey: sectionID)
        removeTemporaryFilesIfUnused(discarded)
    }

    func beginSave(sectionID: UUID) -> SaveSnapshot {
        let draft = draft(for: sectionID)
        for url in draft.attachments where temporaryAttachments.contains(url) {
            inFlightCounts[url, default: 0] += 1
        }
        return SaveSnapshot(sectionID: sectionID, draft: draft)
    }

    func finishSave(_ snapshot: SaveSnapshot, saved: Bool) {
        if saved {
            var current = draft(for: snapshot.sectionID)
            current.attachments.removeAll { snapshot.draft.attachments.contains($0) }
            set(current.attachments, for: snapshot.sectionID)
            if current.text == snapshot.draft.text {
                setText("", for: snapshot.sectionID)
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

    private func set(_ attachments: [URL], for sectionID: UUID) {
        if attachments.isEmpty {
            attachmentsBySection.removeValue(forKey: sectionID)
        } else {
            attachmentsBySection[sectionID] = attachments
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
        let draftedURLs = Set(attachmentsBySection.values.flatMap { $0 })
        for url in urls
        where temporaryAttachments.contains(url)
            && inFlightCounts[url] == nil
            && !draftedURLs.contains(url) {
            try? FileManager.default.removeItem(at: url)
            temporaryAttachments.remove(url)
        }
    }
}
