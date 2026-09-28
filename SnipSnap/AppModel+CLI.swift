import Foundation
import SnipSnapCore

@MainActor
extension AppModel {
    func handleCLIRequest(_ request: SnipCLIRequest) async throws -> SnipCLIReceipt {
        switch request.action {
        case .add(let content, let selector, let agentContext):
            let source = agentContext.map {
                SnipSource(applicationName: "", agentContext: $0)
            }
            let now = Date()
            let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return try await performCLIMutation(scopeToken: request.scopeToken, recover: { snapshot in
                guard let snip = snapshot.snips.first(where: { $0.requestID == request.requestID }),
                      let list = snapshot.lists.first(where: { $0.id == snip.listID })
                else { return nil }
                guard snip.origin == .agent,
                      snip.source == source,
                      abs(snip.createdAt.timeIntervalSince(now)) < 0.001
                else { return nil }
                if LargePastedText.shouldAttach(content) {
                    guard snip.content.isEmpty,
                          snip.attachments.contains(where: { attachment in
                              guard let url = snapshot.attachmentURLs[attachment.id],
                                    let data = try? Data(contentsOf: url) else { return false }
                              return data == Data(content.utf8)
                          }) else { return nil }
                } else if snip.content != cleanContent {
                    return nil
                }
                if let selector {
                    guard SnipListNameAllocator.matching(selector, in: snapshot.lists)?.id
                            == snip.listID else { return nil }
                } else if snip.listID != SnipList.inboxID {
                    return nil
                }
                return SnipCLIReceipt(request: request, status: .success,
                                      snips: [snip], lists: [list])
            }) {
                let archive = try await session.checkedSnapshot(sortedBy: sortMode)
                let listID = try selector.map { try cliList($0, in: archive.lists).id }
                    ?? SnipList.inboxID
                let update = try await session.performLibraryCommand(
                    .add(content: content, origin: .agent, source: source, listID: listID,
                         attachmentURLs: [], requestID: request.requestID, now: now),
                    sortedBy: sortMode
                )
                guard case .add(.added) = update.outcome else {
                    throw SnipCLIRequestError.conflictingRequestID
                }
                guard let snip = update.snapshot.snips.first(where: {
                    $0.requestID == request.requestID
                }), let list = update.snapshot.lists.first(where: { $0.id == snip.listID })
                else { throw SnipLibraryError.invalidStore }
                return (update, SnipCLIReceipt(request: request, status: .success,
                                               snips: [snip], lists: [list]))
            }

        case .listSnips(let selector):
            let archive = try await cliArchive(scopeToken: request.scopeToken)
            let listID = try selector.map { try cliList($0, in: archive.lists).id }
            let snips = Snip.sorted(archive.snips.filter {
                listID == nil || $0.listID == listID
            }, by: .chronological)
            return SnipCLIReceipt(request: request, status: .success, snips: snips,
                                  lists: archive.lists)

        case .showSnip(let id):
            let archive = try await cliArchive(scopeToken: request.scopeToken)
            guard let snip = archive.snips.first(where: { $0.id == id }) else {
                throw SnipLibraryError.snipNotFound
            }
            return SnipCLIReceipt(request: request, status: .success, snips: [snip],
                                  lists: archive.lists)

        case .updateSnip(let id, let content, let expectedUpdatedAt):
            let update = try await performCLIMutation(scopeToken: request.scopeToken) {
                guard editingID != id else { throw SnipCLIRequestError.editingInProgress }
                let update = try await session.performLibraryCommand(
                    .update(id: id, content: content, attachmentURLs: nil,
                            expectedUpdatedAt: expectedUpdatedAt, now: Date()),
                    sortedBy: sortMode
                )
                return (update, update)
            }
            return SnipCLIReceipt(request: request, status: .success,
                                  snips: update.snapshot.snips.filter { $0.id == id })

        case .deleteSnip(let id, let expectedRevision):
            _ = try await performCLIMutation(scopeToken: request.scopeToken) {
                guard editingID != id else { throw SnipCLIRequestError.editingInProgress }
                let archive = try await session.checkedSnapshot(sortedBy: sortMode)
                guard let current = archive.snips.first(where: { $0.id == id }) else {
                    throw SnipLibraryError.snipNotFound
                }
                guard SnipCLIItemRevision.token(snip: current) == expectedRevision else {
                    throw SnipLibraryError.snipChanged
                }
                let update = try await session.performLibraryCommand(
                    .guarded(expectation: SnipLibraryExpectation(expectedSnips: [current]),
                             command: .delete(ids: [id])),
                    sortedBy: sortMode
                )
                _ = try? await session.performLibraryCommand(
                    .pruneAttachments(retaining: []), sortedBy: sortMode
                )
                return (update, update)
            }
            return SnipCLIReceipt(request: request, status: .success, message: "Deleted snip.")

        case .listLists:
            let archive = try await cliArchive(scopeToken: request.scopeToken)
            return SnipCLIReceipt(request: request, status: .success, lists: archive.lists)

        case .showList(let selector):
            let archive = try await cliArchive(scopeToken: request.scopeToken)
            let list = try cliList(selector, in: archive.lists)
            let snips = Snip.sorted(archive.snips.filter { $0.listID == list.id },
                                    by: .chronological)
            return SnipCLIReceipt(request: request, status: .success,
                                  snips: snips, lists: [list],
                                  listRevision: SnipCLIListRevision.token(
                                    list: list, memberIDs: snips.map(\.id)))

        case .createList(let name):
            let update = try await performCLIMutation(scopeToken: request.scopeToken) {
                guard editingID == nil else { throw SnipCLIRequestError.editingInProgress }
                let update = try await session.performLibraryCommand(
                    .createList(name: name, systemImage: "circle.grid.2x2.fill"),
                    sortedBy: sortMode
                )
                return (update, update)
            }
            guard case .listCreated(let list) = update.outcome else {
                throw SnipCLIOutcomeUncertain()
            }
            return SnipCLIReceipt(request: request, status: .success, lists: [list])

        case .updateList(let id, let name, let expectedRevision):
            let update = try await performCLIMutation(scopeToken: request.scopeToken) {
                let archive = try await session.checkedSnapshot(sortedBy: sortMode)
                guard editingID == nil else { throw SnipCLIRequestError.editingInProgress }
                let (current, expectation) = try cliListGuard(
                    id: id, revision: expectedRevision, in: archive
                )
                let update = try await session.performLibraryCommand(
                    .guarded(expectation: expectation,
                             command: .updateList(id: id, name: name,
                                                  systemImage: current.systemImage)),
                    sortedBy: sortMode
                )
                return (update, update)
            }
            return SnipCLIReceipt(request: request, status: .success,
                                  lists: update.snapshot.lists.filter { $0.id == id })

        case .deleteList(let id, let expectedRevision):
            _ = try await performCLIMutation(scopeToken: request.scopeToken) {
                let archive = try await session.checkedSnapshot(sortedBy: sortMode)
                guard editingID == nil else { throw SnipCLIRequestError.editingInProgress }
                let draft = composerDrafts.draft(for: id)
                guard draft.text.isEmpty && draft.attachments.isEmpty else {
                    throw SnipCLIRequestError.draftInProgress
                }
                let (_, expectation) = try cliListGuard(
                    id: id, revision: expectedRevision, in: archive
                )
                let update = try await session.performLibraryCommand(
                    .guarded(expectation: expectation, command: .deleteList(id: id)),
                    sortedBy: sortMode
                )
                return (update, update)
            }
            return SnipCLIReceipt(request: request, status: .success,
                                  message: "Deleted list; its snips moved to Inbox.")
        }
    }

    private func cliArchive(scopeToken: String?) async throws -> SnipLibrarySnapshot {
        let result: Result<SnipLibrarySnapshot, Error> = await withCommandLock {
            guard scopeToken == nil || scopeToken == cliScopeToken else {
                return .failure(SnipCLIRequestError.scopeChanged)
            }
            do { return .success(try await session.checkedSnapshot(sortedBy: sortMode)) }
            catch { return .failure(error) }
        }
        return try result.get()
    }

    private func performCLIMutation<Value: Sendable>(
        scopeToken: String? = nil,
        recover: (@MainActor @Sendable (SnipLibrarySnapshot) -> Value?)? = nil,
        _ mutation: @MainActor @Sendable () async throws -> (SnipLibraryUpdate, Value)
    ) async throws -> Value {
        let result: Result<Value, Error> = await withCommandLock {
            guard scopeToken == nil || scopeToken == cliScopeToken else {
                return .failure(SnipCLIRequestError.scopeChanged)
            }
            switch await performMutationUnlocked(mutation) {
            case .success(let value):
                return .success(value)
            case .failure(let error):
                if error is SnipCLIRequestError {
                    return .failure(error)
                }
                if let libraryError = error as? SnipLibraryError {
                    switch libraryError {
                    case .emptyContent, .snipNotFound, .snipChanged, .duplicateList,
                         .invalidList, .invalidCommand, .modeTransitionInProgress,
                         .readOnlyRecovery:
                        return .failure(error)
                    default:
                        break
                    }
                }
                // A write can commit before persistence reports an error.
                let snapshot = try? await session.checkedSnapshot(sortedBy: sortMode)
                if let snapshot { apply(snapshot) }
                scheduleCloudSync()
                if let snapshot, let recovered = recover?(snapshot) {
                    return .success(recovered)
                }
                return .failure(SnipCLIOutcomeUncertain())
            }
        }
        return try result.get()
    }

    private func cliList(_ selector: String, in lists: [SnipList]) throws -> SnipList {
        guard let list = SnipListNameAllocator.matching(selector, in: lists) else {
            throw SnipLibraryError.invalidList
        }
        return list
    }

    private func cliListGuard(
        id: UUID, revision: String, in archive: SnipLibrarySnapshot
    ) throws -> (SnipList, SnipLibraryExpectation) {
        guard let list = archive.lists.first(where: { $0.id == id }) else {
            throw SnipLibraryError.invalidList
        }
        let memberIDs = Set(archive.snips.filter { $0.listID == id }.map(\.id))
        guard SnipCLIListRevision.token(list: list, memberIDs: Array(memberIDs)) == revision else {
            throw SnipLibraryError.snipChanged
        }
        return (list, SnipLibraryExpectation(
            expectedLists: [list], expectedListMemberships: [id: memberIDs]
        ))
    }

}
