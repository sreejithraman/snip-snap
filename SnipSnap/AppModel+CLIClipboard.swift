import Foundation
import SnipSnapCore

@MainActor
extension AppModel {
    func handleCLIClipboard(_ action: SnipCLIClipboardAction,
                            request: SnipCLIRequest) async throws -> SnipCLIReceipt {
        if case .save(let id, let selector, let revision) = action {
            return try await saveCLIClipboardEntry(id: id, selector: selector,
                                                  revision: revision, request: request)
        }
        let result: Result<SnipCLIReceipt, Error> = await withCommandLock {
            guard request.scopeToken == nil || request.scopeToken == cliScopeToken else {
                return .failure(SnipCLIRequestError.scopeChanged)
            }
            do {
                let entries: [ClipboardEntry]
                let selected: [ClipboardEntry]
                switch action {
                case .status:
                    entries = try await clipboardHistory.checkedCLISnapshot()
                    selected = []
                case .list(let query):
                    guard query.limit == nil || query.limit! > 0 else {
                        throw SnipLibraryError.invalidCommand
                    }
                    entries = try await clipboardHistory.checkedCLISnapshot()
                    selected = query.apply(to: entries)
                case .show(let id):
                    entries = try await clipboardHistory.checkedCLISnapshot()
                    guard let entry = entries.first(where: { $0.id == id }) else {
                        throw SnipCLIClipboardError.entryNotFound
                    }
                    selected = [entry]
                case .restore(let id, _), .setPinned(let id, _, _):
                    entries = try await clipboardHistory.performCLI(action)
                    selected = entries.filter { $0.id == id }
                case .delete, .clear, .setPaused:
                    entries = try await clipboardHistory.performCLI(action)
                    selected = []
                case .save:
                    throw SnipLibraryError.invalidCommand
                }
                return .success(SnipCLIReceipt(
                    request: request, status: .success,
                    extendedResult: .clipboard(SnipCLIClipboardResult(
                        entries: selected.map(SnipCLIClipboardEntry.init),
                        status: SnipCLIClipboardStatus(entries: entries, isPaused: clipboardHistory.isPaused)
                    ))
                ))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    private func saveCLIClipboardEntry(id: UUID, selector: String, revision: String,
                                        request: SnipCLIRequest) async throws -> SnipCLIReceipt {
        // Prepare through the same materialization as Save in the panel. Recheck
        // after file work and under the command lock before adding the snip.
        let entry = try await clipboardHistory.checkedCLIEntry(id: id, revision: revision)
        let resolved = clipboardHistory.resolvedEntry(entry)
        let materialization = try await Task.detached(priority: .utility) {
            try resolved.materializeForSnip()
        }.value
        defer { materialization.removeTemporaryFiles() }
        return try await performCLIMutation(scopeToken: request.scopeToken, recover: { snapshot in
            guard let snip = snapshot.snips.first(where: { $0.requestID == request.requestID }),
                  snip.origin == .clipboard,
                  let list = snapshot.lists.first(where: { $0.id == snip.listID }) else { return nil }
            return SnipCLIReceipt(request: request, status: .success, snips: [snip], lists: [list])
        }) {
            _ = try await clipboardHistory.checkedCLIEntry(id: id, revision: revision)
            let archive = try await session.checkedSnapshot(sortedBy: sortMode)
            let list = try cliList(selector, in: archive.lists)
            let update = try await session.performLibraryCommand(
                .guarded(expectation: SnipLibraryExpectation(requiredListIDs: [list.id]), command: .add(
                    content: materialization.text, origin: .clipboard, source: materialization.source,
                    listID: list.id, attachmentURLs: materialization.fileURLs,
                    requestID: request.requestID, now: Date()
                )), sortedBy: sortMode
            )
            let saved = update.snapshot.snips.filter { $0.requestID == request.requestID }
            let message: String?
            if case .add(.duplicate) = update.outcome { message = "This clipboard entry is already saved." }
            else { message = nil }
            let entries = clipboardHistory.entries
            return (update, SnipCLIReceipt(
                request: request, status: .success, snips: saved, lists: [list], message: message,
                extendedResult: .clipboard(.init(
                    entries: entries.filter { $0.id == id }.map(SnipCLIClipboardEntry.init),
                    status: .init(entries: entries, isPaused: clipboardHistory.isPaused)
                ))
            ))
        }
    }
}
