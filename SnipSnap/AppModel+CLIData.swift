import Foundation
import SnipSnapCore

@MainActor
extension AppModel {
    func handleCLIDataRequest(_ request: SnipCLIRequest, action: SnipCLIDataAction) async throws -> SnipCLIReceipt {
        switch action {
        case .exportBackup(let path):
            return try await cliDataLocked(request) {
                let archive = try await session.archive()
                try await writeBackup(archive, at: URL(fileURLWithPath: path))
                return cliDataReceipt(request, result: .init(exportPath: path), message: "Exported backup.")
            }

        case .previewBackup(let path):
            return try await cliDataLocked(request) {
                guard pendingImportPreview == nil else { throw SnipCLIRequestError.editingInProgress }
                let url = URL(fileURLWithPath: path)
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    let preview = try await session.previewImport(from: url)
                    cliImportPreviewID = preview.id
                    return cliDataReceipt(request, result: .init(importPreview: .init(preview)))
                } catch {
                    cliImportPreviewID = nil
                    throw error
                }
            }

        case .cancelBackup(let previewID):
            return try await cliDataLocked(request) {
                guard cliImportPreviewID == previewID else { throw SnipLibraryError.importChanged }
                await session.cancelImport(id: previewID)
                cliImportPreviewID = nil
                return cliDataReceipt(request, result: .init(), message: "Cancelled backup preview.")
            }

        case .importBackup(let previewID):
            return try await performCLIMutation(scopeToken: request.scopeToken) {
                guard editingID == nil else { throw SnipCLIRequestError.editingInProgress }
                guard cliImportPreviewID == previewID else { throw SnipLibraryError.importChanged }
                guard composerDrafts.draftListIDs().allSatisfy({
                    let draft = composerDrafts.draft(for: $0)
                    return draft.text.isEmpty && draft.attachments.isEmpty
                }) else { throw SnipCLIRequestError.draftInProgress }
                do {
                    guard let (result, recovery) = try await session.applyPendingImport(
                        id: previewID, sortedBy: sortMode
                    ) else { throw SnipLibraryError.importChanged }
                    cliImportPreviewID = nil
                    recoverySnapshot = recovery
                    let receipt = cliDataReceipt(request, result: .init(
                        addedSnipCount: result.addedSnipCount,
                        recoveredSnipCount: result.recoveredSnipCount), message: "Imported backup.")
                    return (SnipLibraryUpdate(snapshot: result.snapshot, outcome: .none), receipt)
                } catch {
                    cliImportPreviewID = nil
                    throw error
                }
            }

        case .listRecovery:
            return try await cliDataLocked(request) {
                let archive = try await session.checkedSnapshot(sortedBy: sortMode)
                let recovery = try await session.checkedRecovery()
                return SnipCLIReceipt(request: request, status: .success, snips: archive.snips,
                    lists: archive.lists, extendedResult: .data(.init(
                        recoveredRecords: cliRecoveredRecords(recovery, archive: archive))))
            }

        case .resolveRecovery(let id, let choice, let editedSnip, let editedList, let revision):
            return try await performCLIMutation(scopeToken: request.scopeToken) {
                guard editingID == nil else { throw SnipCLIRequestError.editingInProgress }
                let archive = try await session.checkedSnapshot(sortedBy: sortMode)
                let recovery = try await session.checkedRecovery()
                guard let record = cliRecoveredRecords(recovery, archive: archive).first(where: {
                    $0.record.id == id
                }) else { throw SnipLibraryError.recoveryNotFound }
                guard record.revision == revision else { throw SnipLibraryError.recoveryChanged }
                let selected = try cliRecoveryChoice(choice, record: record.record,
                    editedSnip: editedSnip, editedList: editedList)
                let expectation: SnipRecoveryExpectation
                switch record.record {
                case .snip(let recovered):
                    expectation = .init(record: record.record,
                        currentSnip: archive.snips.first { $0.id == recovered.currentSnipID })
                case .list(let recovered):
                    expectation = .init(record: record.record,
                        currentList: archive.lists.first { $0.id == recovered.currentListID })
                }
                guard let state = try await session.resolveRecovery(id, choice: selected,
                    expectation: expectation, sortedBy: sortMode)
                else { throw SnipLibraryError.recoveryNotFound }
                recoverySnapshot = state.recovery
                let receipt = SnipCLIReceipt(request: request, status: .success,
                    snips: state.library.snips, lists: state.library.lists,
                    message: "Resolved recovered edit.", extendedResult: .data(.init(
                        recoveredRecords: cliRecoveredRecords(state.recovery, archive: state.library))))
                return (SnipLibraryUpdate(snapshot: state.library, outcome: .none), receipt)
            }

        case .listDrafts, .showDraft, .listRecoveredDrafts:
            return try await cliDataLocked(request) {
                let archive = try await session.checkedSnapshot(sortedBy: sortMode)
                let drafts: [SnipCLIDraft]
                switch action {
                case .showDraft(let selector):
                    drafts = [cliDraft(try cliList(selector, in: archive.lists).id)]
                case .listRecoveredDrafts:
                    drafts = cliRecoveredDrafts()
                default:
                    let ids = Set(archive.lists.map(\.id)).union(composerDrafts.draftListIDs())
                    drafts = ids.sorted { $0.uuidString < $1.uuidString }.map { cliDraft($0) }
                }
                return cliDataReceipt(request, result: .init(drafts: drafts))
            }

        case .saveDraftAsSnip(let selector, let destination, let revision):
            return try await performCLIMutation(scopeToken: request.scopeToken) {
                guard editingID == nil else { throw SnipCLIRequestError.editingInProgress }
                let archive = try await session.checkedSnapshot(sortedBy: sortMode)
                let list = try cliList(selector, in: archive.lists)
                let destinationList = try destination.map { try cliList($0, in: archive.lists) } ?? list
                guard cliDraft(list.id).revision == revision else { throw SnipLibraryError.snipChanged }
                let snapshot = composerDrafts.beginSave(listID: list.id)
                var finished = false
                defer {
                    if !finished { composerDrafts.finishSave(snapshot, saved: false) }
                    flushComposerDrafts()
                }
                let update = try await session.performLibraryCommand(
                    .guarded(expectation: SnipLibraryExpectation(expectedLists:
                        list.id == destinationList.id ? [list] : [list, destinationList]), command:
                        .add(content: snapshot.draft.text, origin: .quickEntry, source: nil,
                             listID: destinationList.id, attachmentURLs: snapshot.draft.attachments,
                             requestID: request.requestID, now: Date())), sortedBy: sortMode)
                guard case .add(.added) = update.outcome else {
                    throw SnipCLIRequestError.conflictingRequestID
                }
                // Finish before reading the next draft revision for the receipt.
                composerDrafts.finishSave(snapshot, saved: true)
                finished = true
                let snips = update.snapshot.snips.filter { $0.requestID == request.requestID }
                let receipt = SnipCLIReceipt(request: request, status: .success, snips: snips,
                    lists: [destinationList], message: "Saved draft as snip.",
                    extendedResult: .data(.init(drafts: [cliDraft(list.id)])))
                return (update, receipt)
            }

        case .saveDraft, .clearDraft, .moveDraft, .moveRecoveredDraft:
            return try await cliDataLocked(request) {
                guard editingID == nil else { throw SnipCLIRequestError.editingInProgress }
                let archive = try await session.checkedSnapshot(sortedBy: sortMode)
                // Public composer actions consult the app's live list set.
                apply(archive)
                let changedIDs: [UUID]
                switch action {
                case .saveDraft(let selector, let text, let paths, let revision):
                    guard !text.isEmpty || !paths.isEmpty else { throw SnipLibraryError.emptyContent }
                    let list = try cliList(selector, in: archive.lists)
                    try cliCheckDraft(list.id, revision: revision)
                    let urls = paths.map { URL(fileURLWithPath: $0) }
                    for url in urls {
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
                        guard values.isRegularFile == true, values.isReadable == true else {
                            throw SnipLibraryError.attachmentCopyFailed
                        }
                    }
                    saveComposerText(text, for: list.id)
                    replaceDraftAttachments(urls, in: list.id)
                    changedIDs = [list.id]
                case .clearDraft(let selector, let revision):
                    let list = try cliList(selector, in: archive.lists)
                    try cliCheckDraft(list.id, revision: revision)
                    clearDraft(for: list.id)
                    changedIDs = [list.id]
                case .moveDraft(let selector, let destination, let revision, let destinationRevision):
                    let source = try cliList(selector, in: archive.lists)
                    let target = try cliList(destination, in: archive.lists)
                    try cliCheckDraft(source.id, revision: revision)
                    try cliCheckDraft(target.id, revision: destinationRevision)
                    if source.id != target.id {
                        if target.id == SnipList.inboxID { moveComposerDraftToInbox(from: source.id) }
                        else {
                            let draft = composerDrafts.draft(for: source.id)
                            let existing = composerDrafts.draft(for: target.id)
                            let separator = existing.text.isEmpty || draft.text.isEmpty ? "" : "\n\n"
                            saveComposerText(existing.text + separator + draft.text, for: target.id)
                            addDraftAttachments(draft.attachments, to: target.id)
                            clearDraft(for: source.id)
                        }
                    }
                    changedIDs = Array(Set([source.id, target.id]))
                case .moveRecoveredDraft(let id, let revision, let destinationRevision):
                    guard let draft = cliRecoveredDrafts().first(where: { $0.listID == id }) else {
                        throw SnipLibraryError.recoveryNotFound
                    }
                    guard draft.revision == revision else { throw SnipLibraryError.snipChanged }
                    try cliCheckDraft(SnipList.inboxID, revision: destinationRevision)
                    moveUnattributedLegacyDraftToInbox(id)
                    changedIDs = [SnipList.inboxID]
                default: throw SnipLibraryError.invalidCommand
                }
                flushComposerDrafts()
                return cliDataReceipt(request, result: .init(drafts: changedIDs.map { cliDraft($0) }),
                                      message: "Updated draft.")
            }
        }
    }

    private func cliDataLocked<Value: Sendable>(
        _ request: SnipCLIRequest, _ operation: @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let result: Result<Value, Error> = await withCommandLock {
            guard request.scopeToken == nil || request.scopeToken == cliScopeToken else {
                return .failure(SnipCLIRequestError.scopeChanged)
            }
            do { return .success(try await operation()) }
            catch { return .failure(error) }
        }
        return try result.get()
    }

    private func cliDataReceipt(_ request: SnipCLIRequest, result: SnipCLIDataResult,
                                message: String? = nil) -> SnipCLIReceipt {
        SnipCLIReceipt(request: request, status: .success, message: message, extendedResult: .data(result))
    }

    private func cliDraft(_ id: UUID) -> SnipCLIDraft {
        let draft = composerDrafts.draft(for: id)
        return SnipCLIDraft(listID: id, text: draft.text,
            attachmentPaths: draft.attachments.map(\.path), scope: composerDraftScope)
    }

    private func cliCheckDraft(_ id: UUID, revision: String) throws {
        guard cliDraft(id).revision == revision else { throw SnipLibraryError.snipChanged }
    }

    private func cliRecoveredDrafts() -> [SnipCLIDraft] {
        unattributedLegacyDrafts.map {
            SnipCLIDraft(listID: $0.id, text: $0.text, attachmentPaths: [],
                scope: ComposerDraftStore.unattributedLegacyScope, isRecovered: true)
        }
    }

    private func cliRecoveredRecords(_ recovery: SnipRecoverySnapshot,
                                      archive: SnipLibrarySnapshot) -> [SnipCLIRecoveredRecord] {
        let snips = (recovery.pendingSnips + recovery.promotedSnips).map { record in
            SnipCLIRecoveredRecord(record: .snip(record),
                currentSnip: archive.snips.first { $0.id == record.currentSnipID }, currentList: nil)
        }
        let lists = recovery.pendingLists.map { record in
            SnipCLIRecoveredRecord(record: .list(record), currentSnip: nil,
                currentList: archive.lists.first { $0.id == record.currentListID })
        }
        return (snips + lists).sorted { $0.record.id.uuidString < $1.record.id.uuidString }
    }

    private func cliRecoveryChoice(_ choice: SnipCLIRecoveryChoice, record: SnipRecoveryRecord,
                                   editedSnip: Snip?, editedList: SnipList?) throws -> SnipRecoveryChoice {
        switch (record, choice) {
        case (_, .keepCurrent): return .keepCurrent
        case (_, .useRecovered): return .useRecovered
        case (.snip(let snip), .keepBoth) where snip.state == .pending: return .keepBoth
        case (.snip(let snip), .editSnip) where snip.state == .pending:
            guard let editedSnip, editedList == nil else { throw SnipLibraryError.invalidRecoveryChoice }
            return .editSnip(editedSnip)
        case (.list, .editList):
            guard let editedList, editedSnip == nil else { throw SnipLibraryError.invalidRecoveryChoice }
            return .editList(editedList)
        default: throw SnipLibraryError.invalidRecoveryChoice
        }
    }
}
