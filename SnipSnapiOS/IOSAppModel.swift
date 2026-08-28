import Foundation
import Observation
import SnipSnapCore

@MainActor
@Observable
final class IOSAppModel {
    private let library: any SnipLibrary

    private(set) var snips: [Snip]
    private(set) var lists: [SnipList]
    var selectedListID: UUID
    var selectedSnipID: UUID?
    var errorMessage: String?

    init(
        library: any SnipLibrary,
        initialSnapshot: SnipLibrarySnapshot = SnipLibrarySnapshot(
            snips: [],
            lists: [.inbox]
        ),
        startupError: String? = nil
    ) {
        self.library = library
        snips = initialSnapshot.snips
        lists = initialSnapshot.lists
        selectedListID = SnipList.inboxID
        errorMessage = startupError
    }

    var selectedList: SnipList {
        lists.first(where: { $0.id == selectedListID }) ?? .inbox
    }

    var selectedSnip: Snip? {
        guard let selectedSnipID else { return nil }
        return snips.first(where: { $0.id == selectedSnipID })
    }

    var visibleSnips: [Snip] {
        snips.filter { $0.listID == selectedListID }
    }

    func load() async {
        apply(await library.snapshot(sortedBy: .chronological))
    }

    @discardableResult
    func createSnip(content: String, in listID: UUID) async -> Bool {
        await perform(
            .add(
                content: content,
                origin: .quickEntry,
                source: nil,
                listID: listID,
                attachmentURLs: [],
                requestID: UUID(),
                now: Date()
            )
        ) { outcome in
            if case .add(.added(let id)) = outcome {
                selectedListID = listID
                selectedSnipID = id
            }
        }
    }

    @discardableResult
    func editSnip(_ snip: Snip, content: String) async -> Bool {
        await perform(
            .update(
                id: snip.id,
                content: content,
                attachmentURLs: nil,
                expectedUpdatedAt: snip.updatedAt,
                now: Date()
            )
        )
    }

    @discardableResult
    func deleteSnip(id: UUID) async -> Bool {
        await perform(.delete(ids: [id])) { _ in
            if selectedSnipID == id { selectedSnipID = nil }
        }
    }

    @discardableResult
    func moveSnip(id: UUID, to listID: UUID) async -> Bool {
        await perform(.moveChronologically(ids: [id], to: listID)) { _ in
            selectedListID = listID
            selectedSnipID = id
        }
    }

    @discardableResult
    func createList(name: String) async -> Bool {
        await perform(.createList(name: name, systemImage: "list.bullet")) { outcome in
            if case .listCreated(let list) = outcome {
                selectedListID = list.id
                selectedSnipID = nil
            }
        }
    }

    @discardableResult
    func renameList(_ list: SnipList, name: String) async -> Bool {
        await perform(.updateList(id: list.id, name: name, systemImage: list.systemImage))
    }

    @discardableResult
    func deleteList(id: UUID) async -> Bool {
        await perform(.deleteList(id: id)) { _ in
            selectedListID = SnipList.inboxID
            selectedSnipID = nil
        }
    }

    private func perform(
        _ command: SnipLibraryCommand,
        afterSuccess: (SnipLibraryOutcome) -> Void = { _ in }
    ) async -> Bool {
        do {
            let update = try await library.perform(command, sortedBy: .chronological)
            apply(update.snapshot)
            afterSuccess(update.outcome)
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func apply(_ snapshot: SnipLibrarySnapshot) {
        snips = snapshot.snips
        lists = snapshot.lists

        if !lists.contains(where: { $0.id == selectedListID }) {
            selectedListID = SnipList.inboxID
        }
        if let selectedSnipID, !snips.contains(where: { $0.id == selectedSnipID }) {
            self.selectedSnipID = nil
        }
    }
}
