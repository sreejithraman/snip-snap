import Foundation
import Observation
import SnipSnapCore
import SnipSnapPersistence

@MainActor
@Observable
final class IOSAppModel {
    private let library: any SnipLibrary

    private(set) var snips: [Snip]
    private(set) var lists: [SnipList]
    private(set) var attachmentURLs: [UUID: URL]
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
        attachmentURLs = initialSnapshot.attachmentURLs
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
    func createSnip(
        content: String,
        in listID: UUID,
        attachmentURLs: [URL] = []
    ) async -> Bool {
        await perform(
            .add(
                content: content,
                origin: .quickEntry,
                source: nil,
                listID: listID,
                attachmentURLs: attachmentURLs,
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
    func editSnip(
        _ snip: Snip,
        content: String,
        attachmentEdits: [SnipAttachmentEdit]? = nil
    ) async -> Bool {
        if let attachmentEdits {
            await perform(
                .editAttachments(
                    snipID: snip.id,
                    content: content,
                    edits: attachmentEdits,
                    expectedUpdatedAt: snip.updatedAt,
                    now: Date()
                )
            )
        } else {
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
    }

    func attachmentURL(for attachmentID: UUID) -> URL? {
        attachmentURLs[attachmentID]
    }

    @discardableResult
    func deleteSnip(id: UUID) async -> Bool {
        let deleted = await perform(.delete(ids: [id])) { _ in
            if selectedSnipID == id { selectedSnipID = nil }
        }
        guard deleted else { return false }
        _ = await perform(.pruneAttachments(retaining: []))
        return true
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
        attachmentURLs = snapshot.attachmentURLs

        if !lists.contains(where: { $0.id == selectedListID }) {
            selectedListID = SnipList.inboxID
        }
        if let selectedSnipID, !snips.contains(where: { $0.id == selectedSnipID }) {
            self.selectedSnipID = nil
        }
    }
}

@MainActor
final class IOSAppGraph {
    let model: IOSAppModel
    let shareImporter: IOSShareImportCoordinator?

    init(
        library: any SnipLibrary,
        shareImports: ShareImportStore?,
        initialSnapshot: SnipLibrarySnapshot,
        startupError: String?,
        shareImportOperation: (@Sendable () async -> Int)? = nil
    ) {
        let model = IOSAppModel(
            library: library,
            initialSnapshot: initialSnapshot,
            startupError: startupError
        )
        self.model = model
        if let shareImportOperation {
            shareImporter = IOSShareImportCoordinator(
                model: model,
                importOperation: shareImportOperation
            )
        } else if let shareImports {
            shareImporter = IOSShareImportCoordinator(
                library: library,
                imports: shareImports,
                model: model
            )
        } else {
            shareImporter = nil
        }
    }
}

@MainActor
final class IOSShareImportCoordinator {
    private let model: IOSAppModel
    private let importOperation: @Sendable () async -> Int
    private var inFlight: Task<Int, Never>?

    convenience init(
        library: any SnipLibrary,
        imports: ShareImportStore,
        model: IOSAppModel
    ) {
        self.init(
            model: model,
            importOperation: {
                await imports.importPending(into: library).failed
            }
        )
    }

    init(
        model: IOSAppModel,
        importOperation: @escaping @Sendable () async -> Int
    ) {
        self.model = model
        self.importOperation = importOperation
    }

    func importPendingAndReload() async {
        if let inFlight {
            _ = await inFlight.value
            return
        }
        let task = Task { [model, importOperation] in
            let failed = await importOperation()
            await model.load()
            if failed > 0 {
                model.errorMessage =
                    "One or more shared items could not be added yet. Snip Snap will try again next time."
            }
            return failed
        }
        inFlight = task
        _ = await task.value
        inFlight = nil
    }
}
