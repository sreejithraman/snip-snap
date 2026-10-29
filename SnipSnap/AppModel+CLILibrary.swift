import AppKit
import Foundation
import Quartz
import SnipSnapCore

@MainActor
extension AppModel {
    func handleCLILibraryRequest(
        _ request: SnipCLIRequest, action: SnipCLILibraryAction,
        to pasteboard: NSPasteboard = .general
    ) async throws -> SnipCLIReceipt {
        switch action {
        case .query(let query):
            let snapshot = try await cliArchive(scopeToken: request.scopeToken)
            return SnipCLIReceipt(request: request, status: .success,
                                  snips: try query.snips(in: snapshot), lists: snapshot.lists)

        case .exportAttachment(let snipID, let attachmentID, let path):
            return try await cliAttachmentEffect(request, snipID: snipID, attachmentID: attachmentID) { attachment in
                let prepared = try await self.prepareAttachments([attachment], for: .export)
                guard let source = prepared[attachment.id] else { throw SnipLibraryError.attachmentCopyFailed }
                let destination = URL(fileURLWithPath: path)
                // copyItem fails if the destination already exists: exports never overwrite files.
                try FileManager.default.copyItem(at: source, to: destination)
                return .init(paths: [destination.path])
            }

        case .previewAttachment(let snipID, let attachmentID):
            return try await cliAttachmentEffect(request, snipID: snipID, attachmentID: attachmentID) { attachment in
                guard let preview = try await self.prepareAttachmentPreview([attachment], selected: attachment) else {
                    throw SnipLibraryError.attachmentCopyFailed
                }
                CLIAttachmentPreview.shared.show(preview.selectedURL)
                return .init()
            }

        case .delete(let references):
            let token = request.requestID
            let count = try await performCLIMutation(scopeToken: request.scopeToken) {
                guard self.editingID == nil || !action.affectedSnipIDs.contains(self.editingID!) else {
                    throw SnipCLIRequestError.editingInProgress
                }
                let snapshot = try await self.session.checkedSnapshot(sortedBy: self.sortMode)
                let snips = try SnipCLISnipReference.resolve(references, in: snapshot)
                let update = try await self.session.delete(
                    ids: Set(snips.map(\.id)), token: token,
                    expectation: .init(expectedSnips: snips), sortedBy: self.sortMode
                )
                return (update, snips.count)
            }
            toast = .deleted(count: count, id: token)
            return SnipCLIReceipt(request: request, status: .success, message: "Deleted \(count) snip(s). Undo is available until the deletion toast expires or the next saved-snips change.",
                                  extendedResult: .library(.init(undoToken: token)))

        case .undo(let token):
            let snapshot = try await performCLIMutation(scopeToken: request.scopeToken) {
                guard self.editingID == nil else { throw SnipCLIRequestError.editingInProgress }
                let deletion = try await self.session.restoreDeletion(token: token, sortedBy: self.sortMode)
                let update: SnipLibraryUpdate?
                if let deletion { update = deletion }
                else { update = try await self.session.restoreDone(token: token, sortedBy: self.sortMode) }
                guard let update else { throw SnipLibraryError.invalidCommand }
                return (update, update.snapshot)
            }
            return SnipCLIReceipt(request: request, status: .success, snips: snapshot.snips,
                                  lists: snapshot.lists, message: "Undid the saved-snips change.")

        case .addFiles(let content, let selector, let paths):
            guard !paths.isEmpty else { throw SnipLibraryError.invalidCommand }
            let now = Date()
            return try await performCLIMutation(scopeToken: request.scopeToken) {
                let snapshot = try await self.session.checkedSnapshot(sortedBy: self.sortMode)
                let listID = try selector.map { try self.cliList($0, in: snapshot.lists).id } ?? SnipList.inboxID
                let update = try await self.session.performLibraryCommand(
                    .add(content: content, origin: .agent, source: nil, listID: listID,
                         attachmentURLs: paths.map { URL(fileURLWithPath: $0) },
                         requestID: request.requestID, now: now), sortedBy: self.sortMode
                )
                guard case .add(.added) = update.outcome else {
                    throw SnipCLIRequestError.conflictingRequestID
                }
                guard let snip = update.snapshot.snips.first(where: { $0.requestID == request.requestID }) else {
                    throw SnipCLIOutcomeUncertain()
                }
                return (update, SnipCLIReceipt(request: request, status: .success, snips: [snip],
                    lists: update.snapshot.lists.filter { $0.id == listID }))
            }

        default:
            typealias FeedbackResult = (update: SnipLibraryUpdate, preservesUndo: Bool, undo: SavedSnipsDoneUndo?, copiedCount: Int?)
            let feedback: FeedbackResult = try await performCLIMutation(
                scopeToken: request.scopeToken, didMutate: { !$0.preservesUndo }
            ) {
                if let editingID = self.editingID,
                   action.affectedSnipIDs.contains(editingID) || action.affectedSnipIDs.isEmpty {
                    throw SnipCLIRequestError.editingInProgress
                }
                let snapshot = try await self.session.checkedSnapshot(sortedBy: self.sortMode)
                let command = try action.command(in: snapshot)
                if case .copy(let references, let markDone) = action {
                    let snips = try SnipCLISnipReference.resolve(references, in: snapshot)
                    guard await self.placeOnClipboardNow(.snips(snips), feedback: .silent, to: pasteboard) else {
                        throw SnipLibraryError.attachmentCopyFailed
                    }
                    if !markDone || snips.allSatisfy({ $0.isPinned || $0.isDone }) {
                        let update = SnipLibraryUpdate(snapshot: snapshot, outcome: .none)
                        return (update, (update, true, nil, snips.count))
                    }
                    do {
                        let change = try await self.session.setDone(
                            ids: Set(snips.map(\.id)), done: true,
                            expectation: .init(expectedSnips: snips), sortedBy: self.sortMode
                        )
                        return (change.update, (change.update, !change.didChange, change.undo, snips.count))
                    } catch {
                        self.presentError(
                            String(localized: "Copied, but couldn’t mark Done. Try marking Done again."),
                            operation: "snip.completion_after_copy", diagnosticCode: diagnosticErrorCode(error)
                        )
                        throw SnipCLIOutcomeUncertain()
                    }
                }
                if case .setDone(let references, let done) = action {
                    let snips = try SnipCLISnipReference.resolve(references, in: snapshot)
                    let change = try await self.session.setDone(
                        ids: Set(snips.map(\.id)), done: done,
                        expectation: .init(expectedSnips: snips), sortedBy: self.sortMode
                    )
                    return (change.update, (change.update, !change.didChange, change.undo, nil))
                }
                let result = try await self.session.performLibraryCommandWithResult(command, sortedBy: self.sortMode)
                return (result.update, (result.update, !result.didChange, nil, nil))
            }
            let update = feedback.update
            if let undo = feedback.undo {
                toast = feedback.copiedCount.map { AppToast.copied(count: $0).addingDoneUndo(undo) }
                    ?? .markedDone(count: undo.count, id: undo.id)
            } else if let count = feedback.copiedCount, !(feedback.preservesUndo && toast?.action != nil) {
                toast = .copied(count: count)
            }
            let returnedSnips: [Snip]
            if case .merge = action {
                guard case .merged(let merged) = update.outcome else { throw SnipCLIOutcomeUncertain() }
                returnedSnips = [merged]
            } else {
                returnedSnips = update.snapshot.snips.filter { action.affectedSnipIDs.contains($0.id) }
            }
            return SnipCLIReceipt(request: request, status: .success, snips: returnedSnips,
                                  lists: update.snapshot.lists, message: "Saved snips updated.",
                                  extendedResult: feedback.undo.map { .library(.init(undoToken: $0.id)) })
        }
    }

    private func cliAttachmentEffect(
        _ request: SnipCLIRequest, snipID: UUID, attachmentID: UUID,
        effect: @MainActor (SnipAttachment) async throws -> SnipCLILibraryResult
    ) async throws -> SnipCLIReceipt {
        let result: Result<SnipCLIReceipt, Error> = await withCommandLock {
            do {
                guard request.scopeToken == nil || request.scopeToken == self.cliScopeToken else {
                    throw SnipCLIRequestError.scopeChanged
                }
                let snapshot = try await self.session.checkedSnapshot(sortedBy: self.sortMode)
                guard let snip = snapshot.snips.first(where: { $0.id == snipID }) else { throw SnipLibraryError.snipNotFound }
                guard let attachment = snip.attachments.first(where: { $0.id == attachmentID }) else {
                    throw SnipLibraryError.attachmentCopyFailed
                }
                let output = try await effect(attachment)
                return .success(SnipCLIReceipt(request: request, status: .success,
                    message: "Attachment ready.", extendedResult: .library(output)))
            } catch { return .failure(error) }
        }
        return try result.get()
    }
}

/// Retains Quick Look's data source for the lifetime of its shared panel.
@MainActor
private final class CLIAttachmentPreview: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = CLIAttachmentPreview()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}
