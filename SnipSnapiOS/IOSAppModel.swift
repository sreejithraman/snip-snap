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
    enum AppearanceTab { case icon, color }

    var name: String
    var systemImage: String
    var color: SnipListColorPreset?
    var appearanceTab: AppearanceTab = .color
    var iconQuery = ""
    fileprivate enum Operation {
        case editing
        case saving
        case cancelling
    }
    fileprivate var operation: Operation = .editing
    var isSaving: Bool { operation != .editing }

    init(list: SnipList, isNew: Bool) {
        name = isNew ? "" : list.name
        systemImage = list.systemImage
        color = list.color
    }
}

@MainActor
@Observable
final class IOSAppModel {
    let session: SavedSnipsSession
    private(set) var libraryRevision = UUID()
    // Nil while replacing the source; libraryRevision names the applied snapshot.
    private(set) var attachmentSourceRevision: UUID? = UUID()
    var isManagingLists = false
    let haptics: IOSHapticFeedback
    private let cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private let diagnostics: AppDiagnosticRecorder
    private let publishShareDestinations: (([SnipList]) -> Void)?

    private(set) var snips: [Snip]
    private(set) var lists: [SnipList]
    private(set) var attachmentURLs: [UUID: URL]
    private(set) var recoverySnapshot: SnipRecoverySnapshot = .empty
    private var preparedAttachments: [UUID: PreparedAttachmentRecord] = [:]
    private var attachmentTransferStates: [UUID: SyncedAttachmentTransferState] = [:]
    @ObservationIgnored private var attachmentPreparations: [UUID: AttachmentPreparationGroup] = [:]
    private var cloudAttachmentKnowledge: CloudAttachmentKnowledge
    @MainActor
    final class AttachmentCapture {
        private let snips: [Snip]
        private let allowsDeletion: Bool
        private(set) var isValid = true

        init(snips: [Snip], allowsDeletion: Bool) {
            self.snips = snips
            self.allowsDeletion = allowsDeletion
        }

        func validate(in currentSnips: [Snip]) {
            guard isValid else { return }
            isValid = snips.allSatisfy { captured in
                guard let current = currentSnips.first(where: { $0.id == captured.id }) else {
                    return allowsDeletion
                }
                return captured.attachments.allSatisfy { current.attachments.contains($0) }
            }
        }
    }

    private struct PendingAttachmentCapture {
        weak var value: AttachmentCapture?
    }
    @ObservationIgnored private var attachmentCaptures: [PendingAttachmentCapture] = []

    func captureAttachments(in snips: [Snip], allowingDeletion: Bool) -> AttachmentCapture {
        let capture = AttachmentCapture(snips: snips, allowsDeletion: allowingDeletion)
        capture.validate(in: self.snips)
        attachmentCaptures.removeAll { $0.value == nil }
        attachmentCaptures.append(PendingAttachmentCapture(value: capture))
        return capture
    }

    private struct PreparedAttachmentRecord {
        var url: URL
        var identity: PreparedAttachmentIdentity?
    }

    /// The preparations of one attachment that are running at the same time.
    private struct AttachmentPreparationGroup {
        var memberCount = 0
        var strongestOutcome = AttachmentPreparationOutcome.cancelled
        /// Shown again when every member is cancelled. Each refresh replaces it.
        var reportedState: SyncedAttachmentTransferState?

        var shownState: SyncedAttachmentTransferState? {
            if strongestOutcome == .succeeded { return .available }
            if memberCount > 0 { return .syncing }
            if strongestOutcome == .failed { return .failed }
            return reportedState
        }
    }
    /// Declared weakest first, so a group keeps the strongest outcome of its members.
    private enum AttachmentPreparationOutcome: Comparable {
        case cancelled
        case failed
        case succeeded
    }
    /// Where attachment files come from once the app knows whether iCloud sync is on.
    private enum AttachmentFileSource: Equatable {
        /// No iCloud handler, or iCloud sync is off: library files are used as they are.
        case libraryFiles
        /// iCloud sync is on. Until its transfer states are current, only verified downloads show.
        case iCloudSync(statesAreCurrent: Bool)
    }
    private enum CloudAttachmentKnowledge {
        /// Whether iCloud sync is on is unknown: never read, being read by `refresh`, or the read failed.
        case unknown(lastKnown: AttachmentFileSource?, refresh: UUID?)
        /// iCloud sync is on and `refresh` is reading its transfer states; the last ones stay in use.
        case readingStates(refresh: UUID, lastStatesAreCurrent: Bool)
        case known(AttachmentFileSource)

        var source: AttachmentFileSource? {
            switch self {
            case .unknown(let lastKnown, .some): lastKnown
            case .unknown: nil
            case .readingStates(_, let lastStatesAreCurrent):
                .iCloudSync(statesAreCurrent: lastStatesAreCurrent)
            case .known(let source): source
            }
        }

        var lastKnownSource: AttachmentFileSource? {
            if case .unknown(let lastKnown, _) = self { return lastKnown }
            return source
        }

        var refresh: UUID? {
            switch self {
            case .unknown(_, let refresh): refresh
            case .readingStates(let refresh, _): refresh
            case .known: nil
            }
        }
    }
    var isCloudSyncActive: Bool {
        if case .iCloudSync = cloudAttachmentKnowledge.lastKnownSource { return true }
        return false
    }
    var backupImport = BackupImportPresentation.idle
    var pendingImportPreview: SnipImportPreview? { backupImport.preview?.value }
    private(set) var selectedPage: LibraryPage = .list(SnipList.inboxID)
    private var selectionRevision: UInt64 = 0
    private(set) var lastSelectedListID: UUID
    var pages: [LibraryPage] { [.clipboard] + lists.map { .list($0.id) } }
    private(set) var editingListID: UUID?
    private struct NewListOrigin {
        let page: LibraryPage
        let lastSelectedListID: UUID
    }
    private struct PendingNewList {
        let id: UUID
        let origin: NewListOrigin
    }
    private var pendingNewList: PendingNewList?
    var newListID: UUID? { pendingNewList?.id }
    var newListOriginPage: LibraryPage? { pendingNewList?.origin.page }
    var newListCancellationPage: LibraryPage {
        let origin = newListOriginPage ?? .list(SnipList.inboxID)
        return pages.contains(origin) ? origin : .list(SnipList.inboxID)
    }
    private var listDrafts: [UUID: InlineListDraft] = [:]
    private(set) var snipEditorDraft: SnipEditorDraft?
    // Creation may still refresh after the editor is visible or has finished.
    private(set) var isCreatingList = false
    private struct QueuedNewListRequest {
        let page: LibraryPage
        let selectionRevision: UInt64
    }
    private enum NewListCancellation {
        case idle
        case cancelling(queued: QueuedNewListRequest?)
    }
    private var newListCancellation: NewListCancellation = .idle
    private var isCancellingNewList: Bool {
        if case .cancelling = newListCancellation { return true }
        return false
    }
    var selectedSnipID: UUID?
    /// A gathering session runs from Select or the first gathered snip until it ends.
    /// A class, so readers of one field don't refresh when another changes.
    @MainActor @Observable fileprivate final class GatheringSession {
        let id = UUID()
        private(set) var snipIDs: Set<UUID> = []
        /// Newest first. Snips gathered together keep their list order.
        private(set) var order: [UUID] = []
        var isExpanded = false

        func replaceSnips(with ids: Set<UUID>, orderingNew: (Set<UUID>) -> [UUID]) {
            order = orderingNew(ids.subtracting(snipIDs)) + order.filter(ids.contains)
            snipIDs = ids
        }
    }
    private var gathering: GatheringSession?
    var isSelectingSnips: Bool { gathering != nil }
    var selectedSnipIDs: Set<UUID> { gathering?.snipIDs ?? [] }
    var isSelectionExpanded: Bool { gathering?.isExpanded ?? false }
    var gatheringSessionID: UUID? { gathering?.id }
    struct NewListMoveRequest {
        let ids: [UUID]
        let sortMode: SnipSortMode
        let selectionSessionID: UUID?
    }
    // Separate from the session: it also serves single-snip moves.
    private(set) var newListMoveRequest: NewListMoveRequest?
    // Spans sessions, so only one gathered action runs at a time.
    private(set) var isPerformingGatheredAction = false
    var isSearchPresented = false {
        didSet {
            if isSearchPresented != oldValue { selectionRevision &+= 1 }
        }
    }
    var searchText = "" {
        didSet { reconcileDoneLimitSelection() }
    }
    var completionFilter: SnipCompletionFilter = .all {
        didSet { reconcileDoneLimitSelection() }
    }
    private var storedOriginFilter: SnipOriginFilter = .all
    var originFilter: SnipOriginFilter {
        get { storedOriginFilter }
        set {
            guard snipEditorDraft == nil else { return }
            storedOriginFilter = newValue
            reconcileDoneLimitSelection()
        }
    }
    private let displayDefaults: UserDefaults
    private(set) var doneLimit: SnipDoneLimit

    func setDoneLimit(_ limit: SnipDoneLimit) {
        guard snipEditorDraft == nil else { return }
        doneLimit = limit
        limit.save(to: displayDefaults)
        reconcileDoneLimitSelection()
    }

    var sortMode: SnipSortMode = .chronological {
        didSet { reconcileDoneLimitSelection() }
    }
    var snackbarAndErrors = SnackbarAndErrorPresentation()
    var toast: AppToast? { snackbarAndErrors.snackbar }
    var failure: AppFailure? { snackbarAndErrors.presentedFailure }
    var latestFailure: AppFailure? { snackbarAndErrors.latestFailure }
    var errorDetails: AppFailure? { snackbarAndErrors.errorDetails }
    var inlineFailure: AppFailure? { snackbarAndErrors.inlineFailure }
    var hasGlobalInlineFailure: Bool { inlineFailure?.surface == .snackbar }
    var errorMessage: String? { failure?.message }
    var errorTitle: String { failure?.title ?? String(localized: "Something Went Wrong") }

    func showLatestErrorDetails() {
        snackbarAndErrors.showLatestErrorDetails()
    }

    func showErrorDetails(_ failure: AppFailure) {
        snackbarAndErrors.showErrorDetails(failure)
    }

    func dismissErrorDetails() {
        snackbarAndErrors.closeErrorDetails()
    }

    func dismissError() {
        snackbarAndErrors.hidePresentedFailure()
    }

    func canRetryFailure(_ failure: AppFailure) -> Bool {
        snackbarAndErrors.undoToRetry(for: failure) != nil
    }

    func retryFailure(_ failure: AppFailure) {
        guard canRetryFailure(failure) else { return }
        retryPendingUndo(failure)
    }

    var pendingUndoFailure: AppFailure? { snackbarAndErrors.pendingUndoFailure }

    func clearCommandFailure(_ operation: StaticString) {
        clearFailure(for: String(describing: operation))
    }

    func clearFailure(for operation: String) {
        guard let failure, failure.operation == operation else { return }
        clearFailure(id: failure.id)
    }

    func clearFailure(id: UUID) {
        snackbarAndErrors.resolvePresentedFailure(id: id)
    }

    init(
        library: any SnipLibrary,
        defaults: UserDefaults = .standard,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsFactory: @escaping SnipLibraryUserActionsFactory = { DirectSnipLibraryUserActions(library: $0) },
        recoveryScope: SnipRecoveryScope? = nil,
        initialSnapshot: SnipLibrarySnapshot = SnipLibrarySnapshot(
            snips: [],
            lists: [.inbox]
        ),
        startupError: String? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil,
        haptics: IOSHapticFeedback = IOSHapticFeedback(),
        diagnostics: AppDiagnosticRecorder = AppDiagnosticRecorder.live,
        publishShareDestinations: (([SnipList]) -> Void)? = nil
    ) {
        displayDefaults = defaults
        doneLimit = SnipDoneLimit.load(from: defaults)
        session = SavedSnipsSession(
            library: library,
            userActions: userActions,
            userActionsFactory: userActionsFactory,
            recoveryScope: recoveryScope
        )
        self.cloudSyncHandler = cloudSyncHandler
        self.haptics = haptics
        self.diagnostics = diagnostics
        self.publishShareDestinations = publishShareDestinations
        cloudAttachmentKnowledge = cloudSyncHandler == nil
            ? .known(.libraryFiles)
            : .unknown(lastKnown: nil, refresh: nil)
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
        lists.first(where: { $0.id == lastSelectedListID }) ?? .inbox
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

    func beginSelectingSnips() {
        if gathering == nil { gathering = GatheringSession() }
    }

    func setSelectionExpanded(_ isExpanded: Bool) {
        guard let gathering, gathering.isExpanded != isExpanded else { return }
        gathering.isExpanded = isExpanded
    }

    func endSelectingSnips() {
        haptics.invalidatePendingFeedback()
        gathering = nil
        newListMoveRequest = nil
    }

    private func replaceGatheredSnips(with ids: Set<UUID>) {
        guard let session = gathering, ids != session.snipIDs else { return }
        // Individual taps prepend the newest item. Bulk selection has a stable list order.
        session.replaceSnips(with: ids) { added in
            Snip.sorted(snips.filter { added.contains($0.id) }, by: sortMode).map(\.id)
        }
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
        reconcileDoneLimitSelection()
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
        beginSelectingSnips()
        replaceGatheredSnips(with: ids)
        haptics.emit(.selection, for: haptics.beginInteraction())
    }

    var selectedSnips: [Snip] {
        let byID = Dictionary(uniqueKeysWithValues: snips.map { ($0.id, $0) })
        return (gathering?.order ?? []).compactMap { byID[$0] }
    }

    func moveDestinations(for snips: [Snip]) -> [SnipList] {
        ListDestinationPurpose.move(sourceListIDs: Set(snips.map(\.listID)))
            .destinations(in: lists)
    }

    func requestNewListMove(snips: [Snip], fromSelection: Bool = false) {
        guard !snips.isEmpty, !isPerformingGatheredAction else { return }
        let selectionSessionID = fromSelection ? gatheringSessionID : nil
        guard !fromSelection || selectionSessionID != nil else { return }
        newListMoveRequest = NewListMoveRequest(
            ids: snips.map(\.id), sortMode: fromSelection ? sortMode : .chronological,
            selectionSessionID: selectionSessionID
        )
    }

    func dismissNewListMove() { newListMoveRequest = nil }

    @discardableResult
    func createListAndMove(_ request: NewListMoveRequest, name: String) async -> Bool {
        guard !isPerformingGatheredAction else { return false }
        isPerformingGatheredAction = true
        defer { isPerformingGatheredAction = false }
        let didMove = await withUserMutation { interaction in
            guard request.selectionSessionID.map({ $0 == gatheringSessionID }) ?? true else { return false }
            let ids = request.ids.filter { id in snips.contains { $0.id == id } }
            guard !ids.isEmpty, let listID = await createListUnlocked(
                name: name, systemImage: "", color: nil, selectCreatedList: false
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
        guard didMove else { return false }
        newListMoveRequest = nil
        if let sessionID = request.selectionSessionID, sessionID == gatheringSessionID,
           selectedSnipIDs.isEmpty {
            endSelectingSnips()
        }
        return true
    }

    /// Admits one gathered action at a time. Returns true when the action succeeded and its
    /// session should end.
    func performGatheredAction(
        requiresEmptySelection: Bool = false, _ action: @MainActor () async -> Bool
    ) async -> Bool {
        guard !isPerformingGatheredAction, let sessionID = gatheringSessionID,
              !selectedSnips.isEmpty else { return false }
        isPerformingGatheredAction = true
        defer { isPerformingGatheredAction = false }
        guard await action(), gatheringSessionID == sessionID else { return false }
        return !requiresEmptySelection || selectedSnips.isEmpty
    }

    var visibleSnips: [Snip] {
        visibleSnips(in: lastSelectedListID)
    }

    func visibleSnips(in listID: UUID) -> [Snip] {
        visibleSnips(in: listID, matching: searchText)
    }

    private func matchingSnips(in listID: UUID, query: String) -> [Snip] {
        Snip.sorted(SnipFilter.apply(
            snips: snips.filter { $0.listID == listID },
            query: query,
            completionFilter: completionFilter,
            originFilter: originFilter,
            sourceLabel: { $0.displaySourceLabel }
        ), by: sortMode)
    }

    func visibleSnips(in listID: UUID, matching query: String) -> [Snip] {
        let ordered = matchingSnips(in: listID, query: query)
        let limited = doneLimit.apply(to: ordered, completionFilter: completionFilter, query: query)
        guard let editingID = snipEditorDraft?.original.id,
              ordered.contains(where: { $0.id == editingID }),
              !limited.contains(where: { $0.id == editingID }) else { return limited }
        let visibleIDs = Set(limited.map(\.id)).union([editingID])
        return ordered.filter { visibleIDs.contains($0.id) }
    }

    private func reconcileDoneLimitSelection() {
        guard !selectedSnipIDs.isEmpty || selectedSnipID != nil else { return }
        var retainedIDs = Set(snips.map(\.id))
        if completionFilter == .all, doneLimit != .unlimited, searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for list in lists {
                let matchingIDs = Set(matchingSnips(in: list.id, query: searchText).map(\.id))
                let visibleIDs = Set(visibleSnips(in: list.id).map(\.id))
                // Gathering survives other filters; only the Done cap removes matching snips.
                retainedIDs.subtract(matchingIDs.subtracting(visibleIDs))
            }
        }
        replaceGatheredSnips(with: selectedSnipIDs.intersection(retainedIDs))
        if let selectedSnipID, !retainedIDs.contains(selectedSnipID) {
            self.selectedSnipID = nil
        }
    }

    var canReorderVisibleSnips: Bool {
        snipEditorDraft == nil
            && visibleSnips.count == snips.filter { $0.listID == lastSelectedListID }.count
            && completionFilter == .all
            && originFilter == .all
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load() async {
        await withSerializedMutation { await loadUnlocked() }
        await refreshAttachmentTransferStates()
    }

    func replaceLibrary(
        _ library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope?
    ) async {
        haptics.invalidatePendingFeedback()
        await withSerializedMutation {
            attachmentSourceRevision = nil
            cloudAttachmentKnowledge = .unknown(lastKnown: nil, refresh: nil)
            replaceAttachmentTransferStates(with: [:])
            preparedAttachments.removeAll()
            attachmentPreparations.removeAll()
            clearPendingUndoToast()
            if let snipEditorDraft { finishInlineSnipEdit(snipEditorDraft) }
            selectedSnipID = nil
            apply(await session.replaceLibrary(
                library,
                recoveryScope: recoveryScope,
                sortedBy: sortMode
            ))
            libraryRevision = UUID()
            attachmentSourceRevision = UUID()
        }
        await refreshAttachmentTransferStates()
    }

    @discardableResult
    func resolveRecovery(_ id: UUID, choice: SnipRecoveryChoice) async -> Bool {
        await withUserMutation { _ in
            do {
                return try await resolveSavedSnipsRecovery(id, choice: choice)
            } catch {
                presentError(error, operation: "recovery.resolve")
                await loadUnlocked()
                scheduleAttachmentTransferStateRefresh()
                return false
            }
        }
    }

#if DEBUG
    func seedAgentSnipsUITestFixtureIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SNIP_SNAP_UI_TESTING"] == "1",
              environment["SNIP_SNAP_UI_TEST_AGENT_SNIPS"] == "1",
              snips.isEmpty else { return }
        for (content, origin) in [
            ("Manual release note", SnipOrigin.quickEntry),
            ("Agent release note", SnipOrigin.agent),
            ("Agent archived note", SnipOrigin.agent)
        ] {
            _ = await performUserAction(.add(
                content: content, origin: origin, source: nil, listID: SnipList.inboxID,
                attachmentURLs: [], requestID: UUID(), now: Date()
            ))
        }
        if let archived = snips.first(where: { $0.content == "Agent archived note" }) {
            _ = await performUserAction(.setDone(ids: [archived.id], done: true))
        }
    }
#endif

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
                      let sessionID, gatheringSessionID == sessionID else { return }
                selectedSnipID = snip.id
                replaceGatheredSnips(with: [snip.id])
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
        copyToast: AppToast? = nil,
        ifStillCurrent: @MainActor @Sendable () -> Bool = { true }
    ) async -> IOSMarkCopiedSnipsDoneResult {
        guard !versions.isEmpty else { return .unchanged }
        return await withSerializedMutation { () -> IOSMarkCopiedSnipsDoneResult in
            guard ifStillCurrent() else { return .unchanged }
            let changing = completionCandidates(versions: versions).filter { !$0.isDone }
            guard !changing.isEmpty else { return .unchanged }
            let changed = await changeCompletion(true, snips: changing, guardingChanges: true, copyToast: copyToast)
            return changed ? .markedDone : .failed
        }
    }

    func openNewList(ifSelectedPageIs expectedPage: LibraryPage? = nil) async {
        guard !isSearchPresented else { return }
        if isCancellingNewList {
            if expectedPage.map({ selectedPage == $0 }) ?? true {
                newListCancellation = .cancelling(queued: QueuedNewListRequest(
                    page: selectedPage, selectionRevision: selectionRevision
                ))
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
        let origin = NewListOrigin(page: selectedPage, lastSelectedListID: lastSelectedListID)
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
                name: String(localized: "New List"), systemImage: "", color: nil,
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
                    self.pendingNewList = PendingNewList(id: createdID, origin: origin)
                    self.selectList(createdID)
                    self.editingListID = createdID
                }
            ) else { return }
            if shouldRollBack {
                let removed = await deleteListUnlocked(
                    id: createdID, feedbackInteraction: nil
                )
                if !removed {
                    pendingNewList = PendingNewList(id: createdID, origin: origin)
                    selectList(createdID)
                    editingListID = createdID
                }
            }
        }
    }

    /// Owns cancellation from presentation settlement through the serialized deletion.
    /// The caller keeps presentation checks here; interrupted motion leaves the draft editable.
    @discardableResult
    func cancelNewList(
        id: UUID,
        beforeDeletion: @MainActor () async -> Bool = { true }
    ) async -> Bool {
        guard let pending = pendingNewList, pending.id == id,
              editingListID == id, !isCancellingNewList,
              let list = lists.first(where: { $0.id == id }) else { return false }
        let draft = listDraft(for: list)
        guard draft.operation == .editing else { return false }
        draft.operation = .cancelling
        newListCancellation = .cancelling(queued: nil)

        let ready = await beforeDeletion()
        let shouldDelete = ready && !Task.isCancelled
        // Removing the page invalidates its SwiftUI task. After motion commits,
        // finish deletion and any queued reopen independently of that task.
        return await Task { @MainActor in
            let cancelled: Bool
            if shouldDelete, pendingNewList?.id == id,
               editingListID == id, listDrafts[id] === draft {
                let previousPage = selectedPage
                lastSelectedListID = lists.contains(where: { $0.id == pending.origin.lastSelectedListID })
                    ? pending.origin.lastSelectedListID : SnipList.inboxID
                selectPage(newListCancellationPage)
                let originSelectionRevision = selectionRevision
                cancelled = await withUserMutation { interaction in
                    await deleteListUnlocked(id: id, feedbackInteraction: interaction)
                }
                if !cancelled, selectionRevision == originSelectionRevision,
                   pages.contains(previousPage) {
                    selectPage(previousPage)
                }
            } else {
                cancelled = false
            }

            let queuedRequest: QueuedNewListRequest?
            switch newListCancellation {
            case .idle: queuedRequest = nil
            case .cancelling(let queued): queuedRequest = queued
            }
            newListCancellation = .idle
            draft.operation = .editing
            if let queuedRequest, selectionRevision == queuedRequest.selectionRevision {
                await openNewList(ifSelectedPageIs: queuedRequest.page)
            }
            return cancelled
        }.value
    }

    @discardableResult
    func saveListDraft(id: UUID) async -> Bool {
        guard let draft = listDrafts[id], draft.operation == .editing,
              editingListID == id,
              let list = lists.first(where: { $0.id == id }) else { return false }
        draft.operation = .saving
        defer { draft.operation = .editing }
        let cleaned = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded = await renameList(
            list, name: cleaned.isEmpty ? list.name : cleaned,
            systemImage: draft.systemImage, color: .set(draft.color)
        )
        if succeeded, listDrafts[id] === draft {
            finishListEditing(id: id)
        }
        return succeeded
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
            pendingNewList = nil
        }
    }

    func editListInline(id: UUID) {
        guard id != SnipList.inboxID else { return }
        selectList(id)
        editingListID = id
    }

    @discardableResult
    func createList(name: String, systemImage: String = "", color: SnipListColorPreset? = nil) async -> Bool {
        await withUserMutation { _ in
            await createListUnlocked(name: name, systemImage: systemImage, color: color) != nil
        }
    }

    @discardableResult
    func renameList(_ list: SnipList, name: String, systemImage: String, color: SnipListColorChange = .keep) async -> Bool {
        guard !(isCancellingNewList && newListID == list.id) else { return false }
        return await withUserMutation { _ in
            await performUserAction(
                .updateList(id: list.id, name: name, systemImage: systemImage, color: color)
            )
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
        snackbarAndErrors.showKeepingUndo(presentedToast)
    }

    func performUndoAction(_ toast: AppToast) async {
        await withUserMutation { interaction in
            await restoreUndo(toast) { restored in
                let kind: IOSHapticFeedback.Kind = toast.action == .undoDelete ? .restored : .reopened
                haptics.emit(restored ? kind : .error, for: interaction)
            }
        }
    }

    private func loadUnlocked() async {
        apply(await session.state(sortedBy: sortMode))
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
        switch cloudAttachmentKnowledge.source {
        case nil:
            return preparedAttachments[attachmentID]?.url
        case .libraryFiles:
            return attachmentURLs[attachmentID]
        case .iCloudSync(let statesAreCurrent):
            if !statesAreCurrent || attachmentTransferStates[attachmentID] != nil {
                return preparedAttachments[attachmentID]?.url
            }
            return attachmentURLs[attachmentID]
        }
    }

    func usableAttachmentURL(for attachmentID: UUID) -> URL? {
        guard let url = attachmentURL(for: attachmentID),
              isAvailablePreparedAttachment(url) else { return nil }
        return url
    }

    func attachmentTransferState(for attachmentID: UUID) -> SyncedAttachmentTransferState {
        if let state = attachmentTransferStates[attachmentID] { return state }
        switch cloudAttachmentKnowledge.source {
        case nil, .iCloudSync(statesAreCurrent: false):
            return .waiting
        case .libraryFiles, .iCloudSync(statesAreCurrent: true):
            return attachmentURLs[attachmentID] == nil ? .waiting : .available
        }
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
        capturedSnipID: UUID? = nil,
        showsFailureAlert: Bool = true,
        onFailure: ((String) -> Void)? = nil,
        onCancellation: (() -> Void)? = nil,
        failureIsRelevant: () -> Bool = { true }
    ) async -> URL? {
        guard let sourceRevision = attachmentSourceRevision else { return nil }
        if let capturedSnipID, !snips.contains(where: { $0.id == capturedSnipID }) {
            guard use == .copy else { return nil }
            do {
                if let fallbackLocalURL, isAvailablePreparedAttachment(fallbackLocalURL) {
                    return fallbackLocalURL
                }
                guard let cloudSyncHandler else { return nil }
                let url = try await cloudSyncHandler.prepareSyncedAttachment(attachmentID, for: .copy)
                guard attachmentSourceRevision == sourceRevision, !Task.isCancelled else { return nil }
                return url
            } catch {
                guard attachmentSourceRevision == sourceRevision else { return nil }
                if error is CancellationError || Task.isCancelled { onCancellation?() }
                else { onFailure?(diagnosticErrorCode(error)) }
                return nil
            }
        }
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
        let source = cloudAttachmentKnowledge.source
        if source == .libraryFiles {
            return localURL
        }
        if source == .iCloudSync(statesAreCurrent: true),
           attachmentTransferStates[attachmentID] == nil,
           let localURL
        {
            return localURL
        }
        var group = attachmentPreparations[attachmentID] ?? AttachmentPreparationGroup(
            reportedState: attachmentTransferStates[attachmentID] ?? .waiting
        )
        group.memberCount += 1
        attachmentPreparations[attachmentID] = group
        attachmentTransferStates[attachmentID] = .syncing
        let identity = preparedAttachmentIdentity(for: attachmentID)
        do {
            let url = try await cloudSyncHandler.prepareSyncedAttachment(attachmentID, for: use)
            guard attachmentSourceRevision == sourceRevision else { return nil }
            let currentIdentity = preparedAttachmentIdentity(for: attachmentID)
            if let identity, let currentIdentity, identity != currentIdentity {
                finishAttachmentPreparation(attachmentID, outcome: .cancelled)
                return nil
            }
            // A captured Copy may finish after ordinary deletion without restoring model entries.
            if identity != nil, currentIdentity == nil {
                attachmentPreparations[attachmentID] = nil
                attachmentTransferStates[attachmentID] = nil
                return use == .copy ? url : nil
            }
            attachmentURLs[attachmentID] = url
            preparedAttachments[attachmentID] = PreparedAttachmentRecord(
                url: url,
                identity: identity ?? currentIdentity
            )
            finishAttachmentPreparation(attachmentID, outcome: .succeeded)
            return url
        } catch is CancellationError {
            guard attachmentSourceRevision == sourceRevision else { return nil }
            finishAttachmentPreparation(attachmentID, outcome: .cancelled)
            onCancellation?()
            return nil
        } catch {
            guard attachmentSourceRevision == sourceRevision else { return nil }
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
                    presentFailure(AppFailure(message: message, operation: "attachment.prepare", diagnosticCode: code))
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
        group.memberCount -= 1
        group.strongestOutcome = max(group.strongestOutcome, outcome)
        attachmentTransferStates[attachmentID] = group.shownState
        attachmentPreparations[attachmentID] = group.memberCount > 0 ? group : nil
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
            presentError(String(localized: "Couldn’t clear downloaded files. Try again."),
                         operation: "attachment.cache_clear", diagnosticCode: diagnosticErrorCode(error))
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
        let currentSnips: [Snip]
        if moveSortMode == .manual {
            let destinationSnips = (await session.state(sortedBy: .manual)).library.snips
                .filter { $0.listID == listID }
            currentSnips = Snip.sorted(destinationSnips, by: .manual)
        } else {
            currentSnips = []
        }
        let command = moveToListCommand(ids: ids, to: listID, sortedBy: moveSortMode, in: currentSnips)
        return await performUserAction(command, feedbackInteraction: feedbackInteraction) { _ in
            // Shared movement must not consume a newer selection, or an ordinary item's selection.
            guard let selectionSessionID, selectionSessionID == gatheringSessionID else { return }
            replaceGatheredSnips(with: selectedSnipIDs.subtracting(moving))
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
        let listID = lastSelectedListID
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

    private func setDoneUnlocked(ids: Set<UUID>, done: Bool, feedbackInteraction: UUID?) async -> Bool {
        let eligible = completionCandidates(ids: ids)
        guard !eligible.isEmpty else { return false }
        return await changeCompletion(
            done, snips: eligible.filter { $0.isDone != done }, guardingChanges: false, copyToast: nil
        ) { changed in
            haptics.emit(changed ? (done ? .markedDone : .reopened) : .error, for: feedbackInteraction)
        }
    }

    var copiedButCouldNotMarkDone: String {
        String(localized: "Copied, but couldn’t mark Done. Try marking the snip Done again.")
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

    private func deleteSnips(ids: Set<UUID>, feedbackInteraction: UUID?) async -> Bool {
        let ids = ids.intersection(snips.map(\.id))
        return await deleteSavedSnips(ids: ids) {
            if let selectedSnipID, ids.contains(selectedSnipID) { self.selectedSnipID = nil }
            replaceGatheredSnips(with: selectedSnipIDs.subtracting(ids))
        } feedback: { deleted in
            haptics.emit(deleted ? .deleted : .error, for: feedbackInteraction)
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
        let result = await runSavedSnipsCommand(command) { result in
            if let feedback, result.didChange {
                haptics.emit(feedback, for: feedbackInteraction)
            }
            afterSuccess(result.update.outcome)
        }
        guard case .failure(let error) = result else { return true }
        presentError(error, operation: command.diagnosticOperation)
        haptics.emit(.error, for: feedbackInteraction)
        return false
    }

    func presentError(
        _ error: any Error,
        operation: StaticString = "app.user_action"
    ) {
        diagnostics.record(.failure(operation: operation, error: error, visibility: .user))
        presentFailure(AppFailure(error: error, operation: operation))
    }

    func presentError(
        _ message: String,
        operation: StaticString,
        diagnosticCode: String
    ) {
        diagnostics.record(.failure(operation: operation, errorCode: diagnosticCode, visibility: .user))
        presentFailure(AppFailure(message: message, operation: operation, diagnosticCode: diagnosticCode))
    }

    func presentFailure(_ failure: AppFailure) {
        snackbarAndErrors.present(failure)
    }

    func expireUnavailableUndoRetry(token: UUID, operation: StaticString) {
        guard snackbarAndErrors.retainsUndo(token) else { return }
        let failure = AppFailure(
            message: String(localized: "Undo is no longer available because the snips changed."),
            operation: operation, diagnosticCode: "undo.unavailable"
        )
        diagnostics.record(.failure(operation: operation, errorCode: failure.code, visibility: .user))
        snackbarAndErrors.replaceRetryUndo(with: failure)
    }

    func backupImportSelectionFailed(_ error: any Error) -> String? {
        let nsError = error as NSError
        guard !(error is CancellationError),
              nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError else { return nil }
        diagnostics.record(.failure(operation: "backup.import_select", error: error, visibility: .user))
        return error.localizedDescription
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
        let operation = backupImport.beginPreview()
        do {
            let preview = try await session.withExclusiveAccess { _ in
                try Task.checkCancellation()
                return try await stageBackupImport(from: url)
            }
            guard !Task.isCancelled, backupImport.present(preview, for: operation) else {
                await discardBackupImport(preview.id)
                throw CancellationError()
            }
        } catch {
            backupImport.failPreview(operation)
            if !(error is CancellationError) {
                diagnostics.record(.failure(operation: "backup.import_preview", error: error, visibility: .user))
            }
            throw error
        }
    }

    func confirmBackupImport() async throws {
        haptics.invalidatePendingFeedback()
        guard let preview = backupImport.preview else { return }
        backupImport = .idle
        do {
            let imported = try await session.withExclusiveAccess { _ in
                try Task.checkCancellation()
                return try await applyBackupImport(preview.id, sortedBy: .chronological)
            }
            presentImportedBackup(imported)
        } catch {
            await discardBackupImport(preview.id)
            if !(error is CancellationError) {
                diagnostics.record(.failure(operation: "backup.import_apply", error: error, visibility: .user))
                await load()
            }
            throw error
        }
    }

    func refreshAfterSavedSnipsCommand() async {
        recoverySnapshot = await session.refreshRecovery()
        scheduleAttachmentTransferStateRefresh()
    }

    func apply(_ state: SavedSnipsSessionState) {
        apply(state.library)
        recoverySnapshot = state.recovery
    }

    func apply(_ snapshot: SnipLibrarySnapshot) {
        attachmentCaptures.removeAll { $0.value == nil }
        for capture in attachmentCaptures { capture.value?.validate(in: snapshot.snips) }
        let removedAttachments = Set(snips.flatMap(\.attachments).map(\.id))
            .subtracting(snapshot.snips.flatMap(\.attachments).map(\.id))
        for id in removedAttachments {
            attachmentPreparations[id] = nil
            attachmentTransferStates[id] = nil
        }
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
        if !lists.contains(where: { $0.id == lastSelectedListID }) {
            rememberSelectedList(SnipList.inboxID)
        }
        if let selectedSnipID, !snips.contains(where: { $0.id == selectedSnipID }) {
            self.selectedSnipID = nil
        }
        if let snipEditorDraft, !snips.contains(where: { $0.id == snipEditorDraft.original.id }) {
            finishInlineSnipEdit(snipEditorDraft)
        }
        reconcileDoneLimitSelection()
        // The share picker reads this catalog from outside the app process.
        publishShareDestinations?(lists)
    }

    private func scheduleAttachmentTransferStateRefresh() {
        guard let revision = attachmentSourceRevision else { return }
        Task { [weak self] in
            guard let self, self.attachmentSourceRevision == revision else { return }
            await self.refreshAttachmentTransferStates()
        }
    }

    private func refreshAttachmentTransferStates() async {
        guard let revision = attachmentSourceRevision else { return }
        guard let cloudSyncHandler else {
            cloudAttachmentKnowledge = .known(.libraryFiles)
            replaceAttachmentTransferStates(with: Dictionary(uniqueKeysWithValues:
                attachmentURLs.keys.map { ($0, .available) }
            ))
            return
        }
        let refresh = UUID()
        let lastKnown = cloudAttachmentKnowledge.lastKnownSource
        cloudAttachmentKnowledge = .unknown(lastKnown: lastKnown, refresh: refresh)
        // A failed read keeps the last known states while iCloud is unavailable.
        let isActive: Bool
        do {
            isActive = try await cloudSyncHandler.isCloudSyncActive()
        } catch {
            guard attachmentSourceRevision == revision, cloudAttachmentKnowledge.refresh == refresh else { return }
            if case .iCloudSync = lastKnown {
                cloudAttachmentKnowledge = .unknown(
                    lastKnown: .iCloudSync(statesAreCurrent: false), refresh: nil
                )
            } else {
                cloudAttachmentKnowledge = .unknown(lastKnown: lastKnown, refresh: nil)
            }
            return
        }
        guard attachmentSourceRevision == revision, cloudAttachmentKnowledge.refresh == refresh else { return }
        guard isActive else {
            cloudAttachmentKnowledge = .known(.libraryFiles)
            replaceAttachmentTransferStates(with: [:])
            preparedAttachments.removeAll()
            return
        }
        // With iCloud sync off, its empty transfer states were current.
        let lastStatesAreCurrent = switch lastKnown {
        case nil: false
        case .libraryFiles: true
        case .iCloudSync(let statesAreCurrent): statesAreCurrent
        }
        cloudAttachmentKnowledge = .readingStates(
            refresh: refresh, lastStatesAreCurrent: lastStatesAreCurrent
        )
        let states: [UUID: SyncedAttachmentTransferState]
        do {
            states = try await cloudSyncHandler.syncedAttachmentStates()
        } catch {
            guard attachmentSourceRevision == revision, cloudAttachmentKnowledge.refresh == refresh else { return }
            cloudAttachmentKnowledge = .known(.iCloudSync(statesAreCurrent: false))
            return
        }
        guard attachmentSourceRevision == revision, cloudAttachmentKnowledge.refresh == refresh else { return }
        replaceAttachmentTransferStates(with: states)
        cloudAttachmentKnowledge = .known(.iCloudSync(statesAreCurrent: true))
        // Failed must show the failure badge, not the downloaded photo.
        // Waiting and syncing keep it, or a refresh brings the spinner back.
        preparedAttachments = preparedAttachments.filter { id, _ in
            guard let state = attachmentTransferStates[id] else { return false }
            return state != .failed
        }
    }

    private func replaceAttachmentTransferStates(
        with states: [UUID: SyncedAttachmentTransferState]
    ) {
        attachmentTransferStates = states
        for id in attachmentPreparations.keys {
            attachmentPreparations[id]?.reportedState = states[id]
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

    func scheduleCloudSync() {
        guard let cloudSyncHandler else { return }
        Task { await cloudSyncHandler.scheduleSyncAfterLocalChange() }
    }

}
