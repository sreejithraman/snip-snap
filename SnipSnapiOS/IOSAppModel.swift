import Foundation
import Observation
import SnipSnapCore
import SnipSnapPersistence

enum LibraryPage: Hashable {
    case clipboard
    case list(UUID)

    var listID: UUID? {
        guard case .list(let id) = self else { return nil }
        return id
    }
}

enum IOSMarkCopiedSnipsDoneResult: Sendable {
    case unchanged
    case markedDone
    case failed
}

typealias IOSCopiedSnipVersions = [UUID: Date]

@MainActor
@Observable
final class InlineListDraft {
    var name: String
    var systemImage: String
    var color: SnipListColorPreset?
    var isSaving = false
    var isCancelling = false

    init(list: SnipList, isNew: Bool) {
        name = isNew ? "" : list.name
        systemImage = list.systemImage
        color = list.color
    }
}

@MainActor
@Observable
final class IOSAppModel {
    private let session: SavedSnipsSession
    private(set) var libraryRevision = UUID()
    var isManagingLists = false
    let haptics: IOSHapticFeedback
    private let cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private let diagnostics: any AppDiagnosticRecording
    private let publishShareDestinations: (([SnipList]) -> Void)?

    private(set) var snips: [Snip]
    private(set) var lists: [SnipList]
    private(set) var attachmentURLs: [UUID: URL]
    private(set) var recoverySnapshot: SnipRecoverySnapshot = .empty
    private var preparedAttachments: [UUID: PreparedAttachmentRecord] = [:]
    private(set) var attachmentTransferStates: [UUID: SyncedAttachmentTransferState] = [:]
    @ObservationIgnored private var attachmentPreparations: [UUID: AttachmentPreparationGroup] = [:]
    private struct PreparedAttachmentRecord {
        var url: URL
        var identity: PreparedAttachmentIdentity?
    }

    private struct AttachmentPreparationGroup {
        var activeCount: Int
        let initialState: SyncedAttachmentTransferState
        var didSucceed = false
        var didFail = false
    }
    private enum AttachmentPreparationOutcome {
        case succeeded
        case cancelled
        case failed
    }
    private(set) var isCloudSyncActive = false
    private var hasKnownCloudSyncActivity: Bool
    private var hasKnownCloudAttachmentStates = false
    private(set) var pendingImportPreview: SnipImportPreview?
    private var pendingImportPreviewID: UUID?
    private var backupImportOperationID: UUID?
    var toast: AppToast?
    private(set) var selectedPage: LibraryPage = .list(SnipList.inboxID)
    private var selectionRevision: UInt64 = 0
    private var lastSelectedListID: UUID
    /// The last saved list stays available for drafts while Clipboard is selected.
    var selectedListID: UUID { lastSelectedListID }
    var pages: [LibraryPage] { [.clipboard] + lists.map { .list($0.id) } }
    var editingListID: UUID?
    var newListID: UUID?
    private struct NewListOrigin {
        let page: LibraryPage
        let selectedListID: UUID
    }
    private var newListOrigin: NewListOrigin?
    var newListOriginPage: LibraryPage? { newListOrigin?.page }
    var newListCancellationPage: LibraryPage {
        let origin = newListOriginPage ?? .list(SnipList.inboxID)
        return pages.contains(origin) ? origin : .list(SnipList.inboxID)
    }
    private var listDrafts: [UUID: InlineListDraft] = [:]
    private(set) var snipEditorDraft: SnipEditorDraft?
    private(set) var isCreatingList = false
    private var isCancellingNewList = false
    private struct QueuedNewListRequest {
        let page: LibraryPage
        let selectionRevision: UInt64
    }
    private var queuedNewListAfterCancel: QueuedNewListRequest?
    var selectedSnipID: UUID?
    var selectedSnipIDs: Set<UUID> = [] {
        didSet {
            let added = selectedSnipIDs.subtracting(oldValue)
            // Individual taps prepend the newest item. Bulk selection has a stable list order.
            let newIDs = Snip.sorted(snips.filter { added.contains($0.id) }, by: sortMode).map(\.id)
            selectedSnipOrder = newIDs + selectedSnipOrder.filter { selectedSnipIDs.contains($0) }
        }
    }
    private var selectedSnipOrder: [UUID] = []
    var isSelectingSnips = false
    var isSelectionExpanded = false
    struct NewListMoveRequest {
        let ids: [UUID]
        let sortMode: SnipSortMode
        let selectionSessionID: UUID?
    }
    var newListMoveRequest: NewListMoveRequest?
    var isPerformingGatheredAction = false
    /// Identifies gathering work across asynchronous move requests.
    @ObservationIgnored private(set) var gatheringSessionID = UUID()
    var isSearchPresented = false {
        didSet {
            if isSearchPresented != oldValue { selectionRevision &+= 1 }
        }
    }
    var searchText = ""
    var completionFilter: SnipCompletionFilter = .all
    var sortMode: SnipSortMode = .chronological
    private struct PresentedError {
        let title: String
        let message: String
    }
    private var presentedError: PresentedError?
    var errorMessage: String? {
        get { presentedError?.message }
        set {
            presentedError = newValue.map {
                PresentedError(title: String(localized: "Something Went Wrong"), message: $0)
            }
        }
    }
    var errorTitle: String { presentedError?.title ?? String(localized: "Something Went Wrong") }

    init(
        library: any SnipLibrary,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsRebinder: SnipLibraryUserActionsRebinder = .direct,
        recoveryScope: SnipRecoveryScope? = nil,
        initialSnapshot: SnipLibrarySnapshot = SnipLibrarySnapshot(
            snips: [],
            lists: [.inbox]
        ),
        startupError: String? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil,
        haptics: IOSHapticFeedback = IOSHapticFeedback(),
        diagnostics: any AppDiagnosticRecording = AppDiagnostics.shared,
        publishShareDestinations: (([SnipList]) -> Void)? = nil
    ) {
        session = SavedSnipsSession(
            library: library,
            userActions: userActions,
            userActionsRebinder: userActionsRebinder,
            recoveryScope: recoveryScope
        )
        self.cloudSyncHandler = cloudSyncHandler
        self.haptics = haptics
        self.diagnostics = diagnostics
        self.publishShareDestinations = publishShareDestinations
        hasKnownCloudSyncActivity = cloudSyncHandler == nil
        snips = initialSnapshot.snips
        lists = initialSnapshot.lists
        attachmentURLs = initialSnapshot.attachmentURLs
        lastSelectedListID = SnipList.inboxID
        if let startupError {
            presentError(
                startupError,
                operation: "app.startup",
                diagnosticCode: "presentation.startup"
            )
        }
    }

    var selectedList: SnipList {
        lists.first(where: { $0.id == selectedListID }) ?? .inbox
    }

    var selectedSnip: Snip? {
        guard let selectedSnipID else { return nil }
        return snips.first(where: { $0.id == selectedSnipID })
    }

    func selectList(_ listID: UUID) {
        selectPage(.list(listID))
    }

    func selectPage(_ page: LibraryPage) {
        haptics.invalidatePendingFeedback()
        if case .list(let listID) = page { lastSelectedListID = listID }
        setSelectedPage(page)
        selectedSnipID = nil
        if page == .clipboard { endSelectingSnips() }
    }

    private func setSelectedPage(_ page: LibraryPage) {
        guard selectedPage != page else { return }
        selectionRevision &+= 1
        selectedPage = page
    }

    private func rememberSelectedList(_ listID: UUID) {
        lastSelectedListID = listID
        if case .list = selectedPage { setSelectedPage(.list(listID)) }
    }

    func endSelectingSnips() {
        haptics.invalidatePendingFeedback()
        selectedSnipIDs = []
        isSelectingSnips = false
        isSelectionExpanded = false
        newListMoveRequest = nil
        gatheringSessionID = UUID()
    }

    func beginEditingSnip(_ id: UUID) {
        haptics.invalidatePendingFeedback()
        selectedSnipID = id
    }

    @discardableResult
    func beginInlineSnipEdit(_ snip: Snip) -> Bool {
        guard snipEditorDraft?.canDismiss != false else { return false }
        guard snipEditorDraft == nil || snipEditorDraft?.original.id == snip.id else { return false }
        endSelectingSnips()
        beginEditingSnip(snip.id)
        if snipEditorDraft == nil {
            snipEditorDraft = SnipEditorDraft(snip: snip)
        }
        return true
    }

    func finishInlineSnipEdit(_ draft: SnipEditorDraft) {
        guard snipEditorDraft === draft else { return }
        draft.discard()
        snipEditorDraft = nil
    }

    func cancelInlineSnipEdit() {
        guard let draft = snipEditorDraft, draft.canDismiss else { return }
        haptics.invalidatePendingFeedback()
        finishInlineSnipEdit(draft)
    }

    func saveInlineSnipEdit(_ draft: SnipEditorDraft) async -> Bool {
        await withUserMutation { interaction in
            guard snipEditorDraft === draft else { return false }
            return await editSnipUnlocked(
                draft.original,
                content: draft.content,
                attachmentEdits: draft.attachments.compactMap(\.libraryEdit),
                feedbackInteraction: interaction
            )
        }
    }

    func selectSnips(_ ids: Set<UUID>) {
        guard ids != selectedSnipIDs else { return }
        selectedSnipIDs = ids
        if !ids.isEmpty { isSelectingSnips = true }
        haptics.emit(.selection, for: haptics.beginInteraction())
    }

    var selectedSnips: [Snip] {
        let byID = Dictionary(uniqueKeysWithValues: snips.map { ($0.id, $0) })
        return selectedSnipOrder.compactMap { byID[$0] }
    }

    func moveDestinations(for snips: [Snip]) -> [SnipList] {
        ListDestinationPurpose.move(sourceListIDs: Set(snips.map(\.listID)))
            .destinations(in: lists)
    }

    func requestNewListMove(snips: [Snip], fromSelection: Bool = false) {
        guard !snips.isEmpty, !isPerformingGatheredAction else { return }
        newListMoveRequest = NewListMoveRequest(
            ids: snips.map(\.id), sortMode: fromSelection ? sortMode : .chronological,
            selectionSessionID: fromSelection ? gatheringSessionID : nil
        )
    }

    @discardableResult
    func createListAndMove(_ request: NewListMoveRequest, name: String) async -> Bool {
        guard !isPerformingGatheredAction else { return false }
        isPerformingGatheredAction = true
        defer { isPerformingGatheredAction = false }
        return await withUserMutation { interaction in
            guard request.selectionSessionID.map({ $0 == gatheringSessionID }) ?? true else { return false }
            let ids = request.ids.filter { id in snips.contains { $0.id == id } }
            guard !ids.isEmpty, let listID = await createListUnlocked(
                name: name, systemImage: "list.bullet", color: nil, selectCreatedList: false
            ) else { return false }
            let moved = await moveSelectionUnlocked(
                ids: ids, to: listID, sortedBy: request.sortMode, feedbackInteraction: interaction,
                selectionSessionID: request.selectionSessionID
            )
            if moved, request.selectionSessionID == nil {
                rememberSelectedList(listID)
                selectedSnipID = ids.first
            }
            return moved
        }
    }

    var visibleSnips: [Snip] {
        visibleSnips(in: selectedListID)
    }

    func visibleSnips(in listID: UUID) -> [Snip] {
        visibleSnips(in: listID, matching: searchText)
    }

    func visibleSnips(in listID: UUID, matching query: String) -> [Snip] {
        let selected = snips.filter { $0.listID == listID }
        let matches = SnipFilter.apply(
            snips: selected,
            query: query,
            completionFilter: completionFilter,
            sourceLabel: { $0.displaySourceLabel }
        )
        return Snip.sorted(matches, by: sortMode)
    }

    var canReorderVisibleSnips: Bool {
        snipEditorDraft == nil
            && completionFilter == .all
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func currentSnip(for recovery: RecoveredSnip) -> Snip? {
        snips.first { $0.id == recovery.currentSnipID }
    }

    func currentList(for recovery: RecoveredListEdit) -> SnipList? {
        lists.first { $0.id == recovery.currentListID }
    }

    func isRecoveredSnip(_ snipID: UUID) -> Bool {
        recoverySnapshot.pendingSnips.contains { $0.id == snipID }
            || recoverySnapshot.promotedSnips.contains { $0.id == snipID }
    }

    func load() async {
        await withSerializedMutation { await loadUnlocked() }
    }

    func replaceLibrary(
        _ library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope?
    ) async {
        haptics.invalidatePendingFeedback()
        await withSerializedMutation {
            clearPendingDeletionToast()
            if let snipEditorDraft { finishInlineSnipEdit(snipEditorDraft) }
            selectedSnipID = nil
            apply(await session.replaceLibrary(
                library,
                recoveryScope: recoveryScope,
                sortedBy: sortMode
            ))
            libraryRevision = UUID()
            await refreshAttachmentTransferStates()
            // A prepare can store a file during either await. This switch must end without one.
            preparedAttachments.removeAll()
        }
    }

    @discardableResult
    func resolveRecovery(_ id: UUID, choice: SnipRecoveryChoice) async -> Bool {
        await withUserMutation { _ in
            await resolveRecoveryUnlocked(id, choice: choice)
        }
    }

    @discardableResult
    func createSnip(
        content: String,
        in listID: UUID,
        attachmentURLs: [URL] = [],
        selectCreatedSnip: Bool = true,
        expectedLibraryRevision: UUID? = nil,
        expectedSourceListID: UUID? = nil
    ) async -> Bool {
        await withUserMutation { interaction in
            if let expectedLibraryRevision, expectedLibraryRevision != libraryRevision { return false }
            if let expectedSourceListID, !lists.contains(where: { $0.id == expectedSourceListID }) { return false }
            return await createSnipUnlocked(
                content: content,
                in: listID,
                attachmentURLs: attachmentURLs,
                selectCreatedSnip: selectCreatedSnip,
                feedbackInteraction: interaction
            )
        }
    }

    @discardableResult
    func editSnip(
        _ snip: Snip,
        content: String,
        attachmentEdits: [SnipAttachmentEdit]? = nil
    ) async -> Bool {
        await withUserMutation { interaction in
            await editSnipUnlocked(
                snip,
                content: content,
                attachmentEdits: attachmentEdits,
                feedbackInteraction: interaction
            )
        }
    }

    @discardableResult
    func deleteSnip(id: UUID) async -> Bool {
        await withUserMutation { interaction in await deleteSnips(ids: [id], feedbackInteraction: interaction) }
    }

    @discardableResult
    func deleteSelection() async -> Bool {
        let ids = existingSelectedSnipIDs
        return await withUserMutation { interaction in
            await deleteSnips(ids: ids, feedbackInteraction: interaction)
        }
    }

    @discardableResult
    func mergeSelection() async -> Bool {
        let ids = existingSelectedSnipIDs
        let sessionID = gatheringSessionID
        return await withUserMutation { interaction in
            guard ids.count >= 2 else { return false }
            return await performUserAction(.merge(ids: ids, now: Date()), feedbackInteraction: interaction) { outcome in
                guard case .merged(let snip) = outcome,
                      gatheringSessionID == sessionID else { return }
                selectedSnipID = snip.id
                selectedSnipIDs = [snip.id]
                if completionFilter == .done { completionFilter = .all }
            }
        }
    }

    @discardableResult
    func moveSnip(id: UUID, to listID: UUID) async -> Bool {
        await withUserMutation { interaction in
            await moveSnipUnlocked(id: id, to: listID, feedbackInteraction: interaction)
        }
    }

    @discardableResult
    func moveSelection(to listID: UUID) async -> Bool {
        let ids = selectedSnips.map(\.id)
        let moveSortMode = sortMode
        let sessionID = gatheringSessionID
        return await withUserMutation { interaction in
            await moveSelectionUnlocked(
                ids: ids, to: listID, sortedBy: moveSortMode, feedbackInteraction: interaction,
                selectionSessionID: sessionID
            )
        }
    }

    @discardableResult
    func placeVisibleSnips(_ orderedIDs: [UUID]) async -> Bool {
        await withUserMutation { _ in await placeVisibleSnipsUnlocked(orderedIDs) }
    }

    @discardableResult
    func setSelectionDone(_ done: Bool) async -> Bool {
        let ids = existingSelectedSnipIDs
        return await withUserMutation { interaction in
            await setDoneUnlocked(ids: ids, done: done, feedbackInteraction: interaction)
        }
    }

    @discardableResult
    func togglePinned(id: UUID) async -> Bool {
        await withUserMutation { interaction in
            await performUserAction(.togglePinned(id: id), feedbackInteraction: interaction)
        }
    }

    @discardableResult
    func toggleDone(id: UUID) async -> Bool {
        await withUserMutation { interaction in
            await toggleDoneUnlocked(id: id, feedbackInteraction: interaction)
        }
    }

    func copiedSnipVersions(ids: Set<UUID>) -> IOSCopiedSnipVersions {
        Dictionary(uniqueKeysWithValues: snips.lazy.filter {
            ids.contains($0.id) && !$0.isPinned && !$0.isDone
        }.map { ($0.id, $0.updatedAt) })
    }

    func markCopiedSnipsDone(
        versions: IOSCopiedSnipVersions,
        ifStillCurrent: @MainActor @Sendable () -> Bool = { true }
    ) async -> IOSMarkCopiedSnipsDoneResult {
        guard !versions.isEmpty else { return .unchanged }
        return await withSerializedMutation { () -> IOSMarkCopiedSnipsDoneResult in
            guard ifStillCurrent() else { return .unchanged }
            let unfinishedIDs = Set(snips.lazy.filter {
                versions[$0.id] == $0.updatedAt && !$0.isPinned && !$0.isDone
            }.map(\.id))
            guard !unfinishedIDs.isEmpty else { return .unchanged }
            let deletionToast = toast?.action == .undoDelete ? toast : nil
            let changed = await setDoneUnlocked(
                ids: unfinishedIDs,
                done: true,
                feedbackInteraction: nil
            )
            if changed, let deletionToast { toast = deletionToast }
            return changed ? .markedDone : .failed
        }
    }

    func openNewList(ifSelectedPageIs expectedPage: LibraryPage? = nil) async {
        guard !isSearchPresented else { return }
        if isCancellingNewList {
            if expectedPage.map({ selectedPage == $0 }) ?? true {
                queuedNewListAfterCancel = QueuedNewListRequest(
                    page: selectedPage, selectionRevision: selectionRevision
                )
            }
            return
        }
        guard expectedPage.map({ selectedPage == $0 }) ?? true else { return }
        if let newListID {
            if lists.contains(where: { $0.id == newListID }) {
                selectList(newListID)
                editingListID = newListID
                return
            }
            finishListEditing(id: newListID)
        }
        guard !isCreatingList else { return }
        let origin = NewListOrigin(page: selectedPage, selectedListID: selectedListID)
        let originSelectionRevision = selectionRevision
        isCreatingList = true
        defer { isCreatingList = false }
        await withUserMutation { _ in
            guard !Task.isCancelled,
                  !isSearchPresented,
                  selectionRevision == originSelectionRevision,
                  expectedPage.map({ selectedPage == $0 }) ?? true else { return }
            var shouldRollBack = false
            guard let createdID = await createListUnlocked(
                name: String(localized: "New List"), systemImage: "list.bullet", color: nil,
                namePolicy: .available, selectCreatedList: false,
                onCreated: { createdID in
                    if Task.isCancelled || self.isSearchPresented
                        || self.selectionRevision != originSelectionRevision
                        || self.selectedPage != origin.page {
                        shouldRollBack = true
                        return
                    }
                    // Showing the editor commits creation. A later refresh may
                    // suspend, but cancelling it must not erase a visible draft.
                    self.searchText = ""
                    self.newListOrigin = origin
                    self.selectList(createdID)
                    self.newListID = createdID
                    self.editingListID = createdID
                }
            ) else { return }
            if shouldRollBack {
                let removed = await deleteListUnlocked(
                    id: createdID, feedbackInteraction: nil
                )
                if !removed {
                    newListOrigin = origin
                    newListID = createdID
                    selectList(createdID)
                    editingListID = createdID
                }
            }
        }
    }

    @discardableResult
    func cancelNewList(id: UUID) async -> Bool {
        guard newListID == id, editingListID == id, !isCancellingNewList else { return false }
        guard listDrafts[id]?.isSaving != true || listDrafts[id]?.isCancelling == true else { return false }
        isCancellingNewList = true
        let origin = newListOrigin ?? NewListOrigin(
            page: .list(SnipList.inboxID), selectedListID: SnipList.inboxID
        )
        let previousPage = selectedPage
        lastSelectedListID = lists.contains(where: { $0.id == origin.selectedListID })
            ? origin.selectedListID : SnipList.inboxID
        let originPage = newListCancellationPage
        selectPage(originPage)
        let originSelectionRevision = selectionRevision
        let cancelled = await withUserMutation { interaction in
            await deleteListUnlocked(id: id, feedbackInteraction: interaction)
        }
        if !cancelled, selectionRevision == originSelectionRevision,
           pages.contains(previousPage) {
            selectPage(previousPage)
        }
        isCancellingNewList = false
        if let queuedRequest = queuedNewListAfterCancel {
            queuedNewListAfterCancel = nil
            if selectionRevision == queuedRequest.selectionRevision {
                await openNewList(ifSelectedPageIs: queuedRequest.page)
            }
        }
        return cancelled
    }

    func listDraft(for list: SnipList) -> InlineListDraft {
        if let draft = listDrafts[list.id] { return draft }
        let draft = InlineListDraft(list: list, isNew: newListID == list.id)
        listDrafts[list.id] = draft
        return draft
    }

    func isListDraftSaving(id: UUID) -> Bool {
        listDrafts[id]?.isSaving == true
    }

    func finishListEditing(id: UUID) {
        listDrafts[id] = nil
        if editingListID == id { editingListID = nil }
        if newListID == id {
            newListID = nil
            newListOrigin = nil
        }
    }

    func editListInline(id: UUID) {
        guard id != SnipList.inboxID else { return }
        selectList(id)
        editingListID = id
    }

    @discardableResult
    func createList(name: String, systemImage: String = "list.bullet", color: SnipListColorPreset? = nil) async -> Bool {
        await withUserMutation { _ in
            await createListUnlocked(name: name, systemImage: systemImage, color: color) != nil
        }
    }

    @discardableResult
    func renameList(_ list: SnipList, name: String, systemImage: String, color: SnipListColorChange = .keep) async -> Bool {
        guard !(isCancellingNewList && newListID == list.id) else { return false }
        return await withUserMutation { _ in
            await renameListUnlocked(list, name: name, systemImage: systemImage, color: color)
        }
    }

    @discardableResult
    func deleteList(id: UUID) async -> Bool {
        await withUserMutation { interaction in await deleteListUnlocked(id: id, feedbackInteraction: interaction) }
    }

    @discardableResult
    func moveList(id: UUID, before destinationID: UUID?) async -> Bool {
        await withUserMutation { _ in
            await performUserAction(.moveList(id: id, before: destinationID))
        }
    }

    func presentToast(_ presentedToast: AppToast) {
        guard toast?.action == nil || presentedToast.action != nil else { return }
        toast = presentedToast
    }

    func performToastAction(_ presentedToast: AppToast) {
        Task { await performToastActionNow(presentedToast) }
    }

    func performToastActionNow(_ presentedToast: AppToast) async {
        guard presentedToast.action == .undoDelete else { return }
        await withUserMutation { interaction in
            await restoreDeletion(token: presentedToast.id, feedbackInteraction: interaction)
        }
    }

    func dismissToast(_ presentedToast: AppToast) {
        guard presentedToast.action == .undoDelete else { return }
        Task {
            await session.withExclusiveAccess { session in
                await session.discardDeletion(token: presentedToast.id, sortedBy: sortMode)
            }
            if toast?.id == presentedToast.id { toast = nil }
        }
    }

    private func loadUnlocked() async {
        apply(await session.state(sortedBy: sortMode))
        await refreshAttachmentTransferStates()
    }

    private func resolveRecoveryUnlocked(
        _ id: UUID,
        choice: SnipRecoveryChoice
    ) async -> Bool {
        do {
            guard let state = try await session.resolveRecovery(
                id,
                choice: choice,
                sortedBy: sortMode
            ) else { return false }
            apply(state)
            scheduleCloudSync()
            return true
        } catch {
            presentError(error)
            await loadUnlocked()
            return false
    }
    }

    private func createSnipUnlocked(
        content: String,
        in listID: UUID,
        attachmentURLs: [URL] = [],
        selectCreatedSnip: Bool = true,
        feedbackInteraction: UUID?
    ) async -> Bool {
        return await performUserAction(
            .add(
                content: content,
                origin: .quickEntry,
                source: nil,
                listID: listID,
                attachmentURLs: attachmentURLs,
                requestID: UUID(),
                now: Date()
            ),
            feedbackInteraction: feedbackInteraction
        ) { outcome in
            if selectCreatedSnip, case .add(.added(let id)) = outcome {
                rememberSelectedList(listID)
                selectedSnipID = id
            }
        }
    }

    func attachmentURL(for attachmentID: UUID) -> URL? {
        if cloudSyncHandler != nil, !hasKnownCloudSyncActivity {
            return preparedAttachments[attachmentID]?.url
        }
        if isCloudSyncActive,
           !hasKnownCloudAttachmentStates || attachmentTransferStates[attachmentID] != nil
        {
            return preparedAttachments[attachmentID]?.url
        }
        return attachmentURLs[attachmentID]
    }

    func usableAttachmentURL(for attachmentID: UUID) -> URL? {
        guard let url = attachmentURL(for: attachmentID),
              isAvailablePreparedAttachment(url) else { return nil }
        return url
    }

    func attachmentTransferState(for attachmentID: UUID) -> SyncedAttachmentTransferState {
        if let state = attachmentTransferStates[attachmentID] { return state }
        if cloudSyncHandler != nil, !hasKnownCloudSyncActivity { return .waiting }
        if isCloudSyncActive, !hasKnownCloudAttachmentStates { return .waiting }
        return attachmentURLs[attachmentID] == nil ? .waiting : .available
    }

    /// Prepared bytes may be cached, but a stale page/search request must not present them.
    func prepareAttachmentPreview(_ attachmentID: UUID) async -> URL? {
        let originRevision = selectionRevision
        let url = await prepareAttachment(
            attachmentID, for: .preview,
            failureIsRelevant: { self.selectionRevision == originRevision }
        )
        guard !Task.isCancelled, selectionRevision == originRevision else { return nil }
        return url
    }

    func prepareAttachment(
        _ attachmentID: UUID,
        for use: SyncedAttachmentUse,
        fallbackLocalURL: URL? = nil,
        showsFailureAlert: Bool = true,
        onFailure: ((String) -> Void)? = nil,
        onCancellation: (() -> Void)? = nil,
        failureIsRelevant: () -> Bool = { true }
    ) async -> URL? {
        if let preparedURL = preparedAttachments[attachmentID]?.url,
           isAvailablePreparedAttachment(preparedURL)
        {
            attachmentTransferStates[attachmentID] = .available
            return preparedURL
        }
        preparedAttachments[attachmentID] = nil
        let localURL = [fallbackLocalURL, attachmentURLs[attachmentID]]
            .compactMap { $0 }
            .first(where: isAvailablePreparedAttachment)
        guard let cloudSyncHandler else { return localURL }
        if hasKnownCloudSyncActivity, !isCloudSyncActive {
            return localURL
        }
        if hasKnownCloudSyncActivity,
           hasKnownCloudAttachmentStates,
           attachmentTransferStates[attachmentID] == nil,
           let localURL
        {
            return localURL
        }
        var group = attachmentPreparations[attachmentID] ?? AttachmentPreparationGroup(
            activeCount: 0,
            initialState: attachmentTransferStates[attachmentID] ?? .waiting
        )
        group.activeCount += 1
        attachmentPreparations[attachmentID] = group
        attachmentTransferStates[attachmentID] = .syncing
        let identity = preparedAttachmentIdentity(for: attachmentID)
        do {
            let url = try await cloudSyncHandler.prepareSyncedAttachment(attachmentID, for: use)
            let currentIdentity = preparedAttachmentIdentity(for: attachmentID)
            if let identity, let currentIdentity, identity != currentIdentity {
                finishAttachmentPreparation(attachmentID, outcome: .cancelled)
                return nil
            }
            attachmentURLs[attachmentID] = url
            preparedAttachments[attachmentID] = PreparedAttachmentRecord(
                url: url,
                identity: identity ?? currentIdentity
            )
            finishAttachmentPreparation(attachmentID, outcome: .succeeded)
            return url
        } catch is CancellationError {
            finishAttachmentPreparation(attachmentID, outcome: .cancelled)
            onCancellation?()
            return nil
        } catch {
            if Task.isCancelled {
                finishAttachmentPreparation(attachmentID, outcome: .cancelled)
                onCancellation?()
                return nil
            }
            if let preparedURL = preparedAttachments[attachmentID]?.url,
               isAvailablePreparedAttachment(preparedURL) {
                finishAttachmentPreparation(attachmentID, outcome: .cancelled)
                return preparedURL
            }
            finishAttachmentPreparation(attachmentID, outcome: .failed)
            let code = diagnosticErrorCode(error)
            switch use {
            case .preview, .open:
                if showsFailureAlert && failureIsRelevant() {
                    let message = String(localized: "Couldn’t download this file. Try again.")
                    if errorMessage != message {
                        diagnostics.record(.failure(
                            operation: "attachment.prepare",
                            errorCode: code,
                            visibility: .user
                        ))
                    }
                    errorMessage = message
                } else {
                    diagnostics.record(.failure(
                        operation: "attachment.prepare",
                        errorCode: code,
                        visibility: .background
                    ))
                }
            case .copy, .export:
                onFailure?(code)
            }
            return nil
        }
    }

    private func finishAttachmentPreparation(
        _ attachmentID: UUID, outcome: AttachmentPreparationOutcome
    ) {
        guard var group = attachmentPreparations[attachmentID] else { return }
        group.activeCount -= 1
        switch outcome {
        case .succeeded: group.didSucceed = true
        case .failed: group.didFail = true
        case .cancelled: break
        }
        if group.didSucceed {
            attachmentTransferStates[attachmentID] = .available
        } else if group.activeCount > 0 {
            attachmentTransferStates[attachmentID] = .syncing
        } else if group.didFail {
            attachmentTransferStates[attachmentID] = .failed
        } else if attachmentTransferStates[attachmentID] == .syncing {
            attachmentTransferStates[attachmentID] = group.initialState
        }
        attachmentPreparations[attachmentID] = group.activeCount > 0 ? group : nil
    }

    private struct PreparedAttachmentIdentity: Equatable {
        var fileName: String
        var byteCount: Int64
    }

    private func preparedAttachmentIdentity(for attachmentID: UUID) -> PreparedAttachmentIdentity? {
        guard let attachment = snips.lazy.flatMap(\.attachments).first(where: { $0.id == attachmentID })
        else { return nil }
        return PreparedAttachmentIdentity(
            fileName: attachment.fileName,
            byteCount: attachment.byteCount
        )
    }

    private func retainPreparedAttachments(in snapshot: SnipLibrarySnapshot) {
        let attachments = Dictionary(
            snapshot.snips.flatMap(\.attachments).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        preparedAttachments = preparedAttachments.filter { id, prepared in
            guard let attachment = attachments[id],
                  let identity = prepared.identity,
                  attachment.fileName == identity.fileName,
                  attachment.byteCount == identity.byteCount,
                  isAvailablePreparedAttachment(prepared.url) else { return false }
            return true
        }
    }

    private func isAvailablePreparedAttachment(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    func clearDownloadedFiles() async {
        haptics.invalidatePendingFeedback()
        guard let cloudSyncHandler else { return }
        do {
            try await cloudSyncHandler.clearDownloadedFiles()
            apply(await session.state(sortedBy: .chronological))
            await refreshAttachmentTransferStates()
            // A prepare can store a file during either await. Clearing must end without one.
            preparedAttachments.removeAll()
        } catch {
            diagnostics.record(.failure(
                operation: "attachment.cache_clear",
                error: error,
                visibility: .user
            ))
            errorMessage = String(localized: "Couldn’t clear downloaded files. Try again.")
        }
    }

    private func editSnipUnlocked(
        _ snip: Snip,
        content: String,
        attachmentEdits: [SnipAttachmentEdit]?,
        feedbackInteraction: UUID?
    ) async -> Bool {
        let command: SnipLibraryCommand
        if let attachmentEdits {
            command = .editAttachments(
                snipID: snip.id,
                content: content,
                edits: attachmentEdits,
                expectedUpdatedAt: snip.updatedAt,
                now: Date()
            )
        } else {
            command = .update(
                id: snip.id,
                content: content,
                attachmentURLs: nil,
                expectedUpdatedAt: snip.updatedAt,
                now: Date()
            )
        }
        return await performUserAction(command, feedbackInteraction: feedbackInteraction)
    }

    private func moveSnipUnlocked(id: UUID, to listID: UUID, feedbackInteraction: UUID?) async -> Bool {
        let moved = await moveSelectionUnlocked(
            ids: [id], to: listID, sortedBy: .chronological, feedbackInteraction: feedbackInteraction
        )
        if moved {
            rememberSelectedList(listID)
            selectedSnipID = id
        }
        return moved
    }

    private func moveSelectionUnlocked(
        ids: [UUID], to listID: UUID, sortedBy moveSortMode: SnipSortMode,
        feedbackInteraction: UUID?, selectionSessionID: UUID? = nil
    ) async -> Bool {
        guard !ids.isEmpty else { return false }
        let moving = Set(ids)
        let command: SnipLibraryCommand
        if moveSortMode == .manual {
            let currentSnips = (await session.state(sortedBy: .manual)).library.snips
            let firstDestinationID = Snip.sorted(
                currentSnips.filter { $0.listID == listID && !moving.contains($0.id) },
                by: .manual
            ).first?.id
            command = .place(ids: ids, in: listID, before: firstDestinationID, basedOn: .manual)
        } else {
            command = .moveChronologically(ids: ids, to: listID)
        }
        return await performUserAction(command, feedbackInteraction: feedbackInteraction) { _ in
            // Shared movement must not consume a newer selection, or an ordinary item's selection.
            guard let selectionSessionID, selectionSessionID == gatheringSessionID else { return }
            selectedSnipIDs.subtract(moving)
            if let selectedSnipID, moving.contains(selectedSnipID) {
                self.selectedSnipID = nil
            }
        }
    }

    private func placeVisibleSnipsUnlocked(_ orderedIDs: [UUID]) async -> Bool {
        guard canReorderVisibleSnips,
            Set(orderedIDs) == Set(visibleSnips.map(\.id)),
            orderedIDs.count == visibleSnips.count
        else { return false }
        let pinnedIDs = visibleSnips.filter(\.isPinned).map(\.id)
        guard Array(orderedIDs.prefix(pinnedIDs.count)) == pinnedIDs else { return false }
        guard orderedIDs != visibleSnips.map(\.id) else { return true }
        let listID = selectedListID
        return await performUserAction(
            .place(ids: orderedIDs, in: listID, before: nil, basedOn: sortMode)
        ) { _ in
            sortMode = .manual
        }
    }

    private func toggleDoneUnlocked(id: UUID, feedbackInteraction: UUID?) async -> Bool {
        guard let snip = snips.first(where: { $0.id == id }), !snip.isPinned else { return false }
        return await setDoneUnlocked(ids: [id], done: !snip.isDone, feedbackInteraction: feedbackInteraction)
    }

    // Every completion control reaches this command, including batch actions.
    private func setDoneUnlocked(ids: Set<UUID>, done: Bool, feedbackInteraction: UUID?) async -> Bool {
        let ids = Set(snips.filter { ids.contains($0.id) && !$0.isPinned }.map(\.id))
        guard !ids.isEmpty else { return false }
        guard snips.contains(where: { ids.contains($0.id) && $0.isDone != done }) else { return true }
        return await performUserAction(.setDone(ids: ids, done: done), feedbackInteraction: feedbackInteraction)
    }

    private func createListUnlocked(
        name: String, systemImage: String, color: SnipListColorPreset?,
        namePolicy: SnipListNamePolicy = .exact, selectCreatedList: Bool = true,
        onCreated: ((UUID) -> Void)? = nil
    ) async -> UUID? {
        var createdID: UUID?
        let succeeded = await performUserAction(
            .createList(name: name, systemImage: systemImage, color: color, namePolicy: namePolicy)
        ) { outcome in
            if case .listCreated(let list) = outcome {
                createdID = list.id
                if selectCreatedList { selectList(list.id) }
                onCreated?(list.id)
            }
        }
        return succeeded ? createdID : nil
    }

    private func renameListUnlocked(
        _ list: SnipList,
        name: String,
        systemImage: String,
        color: SnipListColorChange
    ) async -> Bool {
        await performUserAction(
            .updateList(id: list.id, name: name, systemImage: systemImage, color: color)
        )
    }

    private func deleteListUnlocked(
        id: UUID, feedbackInteraction: UUID?
    ) async -> Bool {
        guard lists.contains(where: { $0.id == id }) else { return false }
        return await performUserAction(
            .deleteList(id: id), feedbackInteraction: feedbackInteraction
        ) { _ in
            finishListEditing(id: id)
        }
    }

    private var existingSelectedSnipIDs: Set<UUID> {
        selectedSnipIDs.intersection(snips.map(\.id))
    }

    private func restoreDeletion(token: UUID, feedbackInteraction: UUID?) async {
        do {
            guard let update = try await session.restoreDeletion(
                token: token,
                sortedBy: sortMode
            ) else { return }
            apply(update.snapshot)
            haptics.emit(.restored, for: feedbackInteraction)
            if toast?.id == token { toast = nil }
            recoverySnapshot = await session.refreshRecovery()
            await refreshAttachmentTransferStates()
            scheduleCloudSync()
        } catch {
            haptics.emit(.error, for: feedbackInteraction)
            presentError(error)
        }
    }

    private func deleteSnips(ids: Set<UUID>, feedbackInteraction: UUID?) async -> Bool {
        let ids = ids.intersection(snips.map(\.id))
        guard !ids.isEmpty else { return false }
        let count = ids.count
        let token = UUID()
        do {
            let update = try await session.delete(
                ids: ids,
                token: token,
                sortedBy: sortMode
            )
            apply(update.snapshot)
            if let selectedSnipID, ids.contains(selectedSnipID) { self.selectedSnipID = nil }
            selectedSnipIDs.subtract(ids)
            toast = .deleted(count: count, id: token)
            haptics.emit(.deleted, for: feedbackInteraction)
            recoverySnapshot = await session.refreshRecovery()
            await refreshAttachmentTransferStates()
            scheduleCloudSync()
            return true
        } catch {
            presentError(error)
            haptics.emit(.error, for: feedbackInteraction)
            return false
        }
    }

    private func feedbackKind(for command: SnipLibraryCommand) -> IOSHapticFeedback.Kind? {
        switch command {
        case .add, .update, .editAttachments: .saved
        case .setDone(_, let done): done ? .markedDone : .reopened
        case .deleteList: .deleted
        case .merge: .merged
        case .moveChronologically(let ids, let listID):
            snips.contains { ids.contains($0.id) && $0.listID != listID } ? .moved : nil
        case .place(let ids, let listID, _, _):
            snips.contains { ids.contains($0.id) && $0.listID != listID } ? .moved : nil
        default: nil
        }
    }

    private func performUserAction(
        _ command: SnipLibraryCommand,
        feedbackInteraction: UUID? = nil,
        afterSuccess: (SnipLibraryOutcome) -> Void = { _ in }
    ) async -> Bool {
        let feedback = feedbackKind(for: command)
        do {
            let update = try await session.performUserCommand(
                command,
                sortedBy: sortMode
            )
            clearPendingDeletionToast()
            apply(update.snapshot)
            if let feedback, update.outcome != .add(.duplicate) {
                haptics.emit(feedback, for: feedbackInteraction)
            }
            afterSuccess(update.outcome)
            recoverySnapshot = await session.refreshRecovery()
            await refreshAttachmentTransferStates()
            scheduleCloudSync()
            return true
        } catch {
            presentError(error)
            haptics.emit(.error, for: feedbackInteraction)
            return false
        }
    }

    func presentError(
        _ error: any Error,
        operation: StaticString = "app.user_action"
    ) {
        diagnostics.record(.failure(operation: operation, error: error, visibility: .user))
        presentedError = PresentedError(
            title: error as? SnipLibraryError == .duplicateList
                ? String(localized: "Name Already Used")
                : String(localized: "Something Went Wrong"),
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
    }

    func presentError(
        _ message: String,
        operation: StaticString,
        diagnosticCode: String
    ) {
        diagnostics.record(.failure(
            operation: operation,
            errorCode: diagnosticCode,
            visibility: .user
        ))
        presentedError = PresentedError(
            title: String(localized: "Something Went Wrong"),
            message: message
        )
    }

    private func clearPendingDeletionToast() {
        guard let toast, toast.action == .undoDelete else { return }
        self.toast = nil
    }

    func createBackup(at destination: URL) async throws {
        haptics.invalidatePendingFeedback()
        let archive = try await session.withExclusiveAccess { session in
            try await session.archive()
        }
        try await JSONSnipArchiveTransfer.write(archive, to: destination) { @MainActor [self] attachment in
            guard let url = await prepareAttachment(
                attachment.id,
                for: .export,
                fallbackLocalURL: archive.attachmentURLs[attachment.id],
                showsFailureAlert: false
            ) else {
                try Task.checkCancellation()
                throw SnipLibraryError.attachmentCopyFailed
            }
            return url
        }
    }

    func previewBackupImport(from url: URL) async throws {
        haptics.invalidatePendingFeedback()
        cancelBackupImport()
        let operationID = UUID()
        backupImportOperationID = operationID
        do {
            let preview = try await session.withExclusiveAccess { session in
                try Task.checkCancellation()
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                return try await session.previewImport(from: url)
            }
            guard backupImportOperationID == operationID, !Task.isCancelled else {
                await session.withExclusiveAccess { session in
                    await session.cancelImport(id: preview.id)
                }
                throw CancellationError()
            }
            pendingImportPreviewID = preview.id
            pendingImportPreview = preview.value
        } catch {
            if backupImportOperationID == operationID {
                backupImportOperationID = nil
                pendingImportPreviewID = nil
                pendingImportPreview = nil
            }
            if !(error is CancellationError) {
                diagnostics.record(.failure(operation: "backup.import_preview", error: error, visibility: .user))
            }
            throw error
        }
    }

    func cancelBackupImport() {
        backupImportOperationID = nil
        let id = pendingImportPreviewID
        pendingImportPreviewID = nil
        pendingImportPreview = nil
        guard let id else { return }
        Task {
            await session.withExclusiveAccess { session in
                await session.cancelImport(id: id)
            }
        }
    }

    func confirmBackupImport() async throws {
        haptics.invalidatePendingFeedback()
        guard pendingImportPreview != nil, let id = pendingImportPreviewID else { return }
        pendingImportPreviewID = nil
        pendingImportPreview = nil
        backupImportOperationID = nil
        do {
            guard let (result, recovery) = try await session.withExclusiveAccess({ session in
                try Task.checkCancellation()
                return try await session.applyPendingImport(id: id, sortedBy: .chronological)
            }) else { return }
            clearPendingDeletionToast()
            apply(result.snapshot)
            recoverySnapshot = recovery
        } catch {
            await session.withExclusiveAccess { session in
                await session.cancelImport(id: id)
            }
            if !(error is CancellationError) {
                diagnostics.record(.failure(operation: "backup.import_apply", error: error, visibility: .user))
                await load()
            }
            throw error
        }
    }

    private func apply(_ state: SavedSnipsSessionState) {
        apply(state.library)
        recoverySnapshot = state.recovery
    }

    private func apply(_ snapshot: SnipLibrarySnapshot) {
        snips = snapshot.snips
        lists = snapshot.lists
        attachmentURLs = snapshot.attachmentURLs
        retainPreparedAttachments(in: snapshot)
        if let newListID, !lists.contains(where: { $0.id == newListID }) {
            finishListEditing(id: newListID)
        }
        if let editingListID, !lists.contains(where: { $0.id == editingListID }) {
            finishListEditing(id: editingListID)
        }
        if !lists.contains(where: { $0.id == selectedListID }) {
            rememberSelectedList(SnipList.inboxID)
        }
        if let selectedSnipID, !snips.contains(where: { $0.id == selectedSnipID }) {
            self.selectedSnipID = nil
        }
        if let snipEditorDraft, !snips.contains(where: { $0.id == snipEditorDraft.original.id }) {
            finishInlineSnipEdit(snipEditorDraft)
        }
        selectedSnipIDs.formIntersection(snips.map(\.id))
        // The share picker reads this catalog from outside the app process.
        publishShareDestinations?(lists)
    }

    private func refreshAttachmentTransferStates() async {
        guard let cloudSyncHandler else {
            isCloudSyncActive = false
            hasKnownCloudSyncActivity = true
            hasKnownCloudAttachmentStates = true
            attachmentTransferStates = Dictionary(uniqueKeysWithValues:
                attachmentURLs.keys.map { ($0, .available) }
            )
            return
        }
        hasKnownCloudSyncActivity = false
        do {
            isCloudSyncActive = try await cloudSyncHandler.isCloudSyncActive()
            hasKnownCloudSyncActivity = true
            guard isCloudSyncActive else {
                hasKnownCloudAttachmentStates = true
                attachmentTransferStates = [:]
                preparedAttachments.removeAll()
                return
            }
            attachmentTransferStates = try await cloudSyncHandler.syncedAttachmentStates()
            hasKnownCloudAttachmentStates = true
            // Failed must show the failure badge, not the downloaded photo.
            // Waiting and syncing keep it, or a refresh brings the spinner back.
            preparedAttachments = preparedAttachments.filter { id, _ in
                guard let state = attachmentTransferStates[id] else { return false }
                return state != .failed
            }
        } catch {
            if isCloudSyncActive { hasKnownCloudAttachmentStates = false }
            // Keep the last known states while iCloud is unavailable.
        }
    }

    private func withUserMutation<Result: Sendable>(
        _ operation: @MainActor @Sendable (UUID?) async -> Result
    ) async -> Result {
        let interaction = haptics.beginInteraction()
        return await withSerializedMutation { await operation(interaction) }
    }

    private func withSerializedMutation<Result: Sendable>(
        _ operation: @MainActor @Sendable () async -> Result
    ) async -> Result {
        await session.withExclusiveAccess { _ in await operation() }
    }

    private func scheduleCloudSync() {
        guard let cloudSyncHandler else { return }
        Task { await cloudSyncHandler.scheduleSyncAfterLocalChange() }
    }

}
