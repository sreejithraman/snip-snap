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
    private let session: SavedSnipsSession
    @ObservationIgnored private var application = ApplicationState()
    private struct ApplicationState {
        var libraryRevision: UUID = UUID()
        var snips: [Snip] = []
        var lists: [SnipList] = [.inbox]
        var attachmentURLs: [UUID: URL] = [:]
        var recoverySnapshot: SnipRecoverySnapshot = .empty
        var preparedAttachments: [UUID: PreparedAttachmentRecord] = [:]
        var attachmentTransferStates: [UUID: SyncedAttachmentTransferState] = [:]
        var attachmentFileRevision: UUID = UUID()
        var cloudAttachmentKnowledge: CloudAttachmentKnowledge = .unknown(lastKnown: nil, refresh: nil)
        var selectedPage: LibraryPage = .list(SnipList.inboxID)
        var selectionRevision: UInt64 = 0
        var lastSelectedListID: UUID = SnipList.inboxID
        var editingListID: UUID? = nil
        var pendingNewList: PendingNewList? = nil
        var listDrafts: [UUID: InlineListDraft] = [:]
        var snipEditorDraft: SnipEditorDraft? = nil
        var selectedSnipID: UUID? = nil
        var gathering: GatheringSession? = nil
        var snackbarAndErrors: SnackbarAndErrorPresentation = SnackbarAndErrorPresentation()
        var source: SnipLibraryReadSource?
        var target: SnipLibraryApplicationTarget?
        var files: Result<[UUID: SnipLibraryFileObservation], any Error>?
        var publication: SnipLibraryReadPublication?
    }
    private(set) var libraryRevision: UUID {
        get { access(keyPath: \.libraryRevision); return application.libraryRevision }
        set { withMutation(keyPath: \.libraryRevision) { application.libraryRevision = newValue } }
    }
    var isManagingLists = false
    let haptics: IOSHapticFeedback
    private let cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private let diagnostics: AppDiagnosticRecorder
    private let publishShareDestinations: (([SnipList]) -> Void)?
    @ObservationIgnored private var checkedCatalogPublisher: ShareListCatalogPublisher?

    private(set) var snips: [Snip] {
        get { access(keyPath: \.snips); return application.snips }
        set { withMutation(keyPath: \.snips) { application.snips = newValue } }
    }
    private(set) var lists: [SnipList] {
        get { access(keyPath: \.lists); return application.lists }
        set { withMutation(keyPath: \.lists) { application.lists = newValue } }
    }
    private(set) var attachmentURLs: [UUID: URL] {
        get { access(keyPath: \.attachmentURLs); return application.attachmentURLs }
        set { withMutation(keyPath: \.attachmentURLs) { application.attachmentURLs = newValue } }
    }
    private(set) var recoverySnapshot: SnipRecoverySnapshot {
        get { access(keyPath: \.recoverySnapshot); return application.recoverySnapshot }
        set { withMutation(keyPath: \.recoverySnapshot) { application.recoverySnapshot = newValue } }
    }
    private var preparedAttachments: [UUID: PreparedAttachmentRecord] {
        get { access(keyPath: \.preparedAttachments); return application.preparedAttachments }
        set { withMutation(keyPath: \.preparedAttachments) { application.preparedAttachments = newValue } }
    }
    private var attachmentTransferStates: [UUID: SyncedAttachmentTransferState] {
        get { access(keyPath: \.attachmentTransferStates); return application.attachmentTransferStates }
        set { withMutation(keyPath: \.attachmentTransferStates) { application.attachmentTransferStates = newValue } }
    }
    @ObservationIgnored private var attachmentPreparations: [UUID: AttachmentPreparationGroup] = [:]
    private var attachmentFileRevision: UUID {
        get { access(keyPath: \.attachmentFileRevision); return application.attachmentFileRevision }
        set { withMutation(keyPath: \.attachmentFileRevision) { application.attachmentFileRevision = newValue } }
    }
    @ObservationIgnored private var attachmentCopyCaptures: [WeakAttachmentCopyCapture] = []
    private var isReplacingAttachmentSource = false
    @ObservationIgnored private var attachmentStateRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var attachmentStateRefreshPending = false
    @ObservationIgnored private var attachmentStateRefreshWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    struct CheckedApplication: Sendable {
        let read: SnipLibraryReadObservation
        let attachments: SyncedAttachmentReadObservation?
    }
    private enum CheckedApplicationRequest: Sendable {
        case load
        case replace(any SnipLibrary, SnipRecoveryScope?)
        case target(SnipLibraryApplicationTarget)

        var target: SnipLibraryApplicationTarget? {
            if case .target(let target) = self { return target }
            return nil
        }
    }
    @MainActor
    final class SyncApplicationCompletion {
        weak var settings: SyncedContentSettingsModel?
        weak var clipboard: IOSClipboardModel?
        let start: SyncedContentSyncStart
        let stoppedIssue: SyncedContentSyncIssue?
        let enabling: Bool
        let removalCompleted: Bool?
        init(settings: SyncedContentSettingsModel, clipboard: IOSClipboardModel, start: SyncedContentSyncStart,
             stoppedIssue: SyncedContentSyncIssue? = nil, enabling: Bool = false, removalCompleted: Bool? = nil) {
            self.settings = settings; self.clipboard = clipboard; self.start = start
            self.stoppedIssue = stoppedIssue; self.enabling = enabling; self.removalCompleted = removalCompleted
        }
    }
    @ObservationIgnored private var activeApplicationTarget: SnipLibraryApplicationTarget?
    @ObservationIgnored private var applicationCompletions: [ObjectIdentifier: SyncApplicationCompletion] = [:]
    @ObservationIgnored private var checkedApplicationTargets: [UUID: SnipLibraryApplicationTarget] = [:]
    @ObservationIgnored private var pendingCheckedApplication: CheckedApplicationRequest?
    @ObservationIgnored private var checkedApplicationWaiters: [UUID: AsyncThrowingStream<CheckedApplication, any Error>.Continuation] = [:]
    @ObservationIgnored private var checkedApplicationResult: Result<CheckedApplication, any Error>?
    private var cloudAttachmentKnowledge: CloudAttachmentKnowledge {
        get { access(keyPath: \.cloudAttachmentKnowledge); return application.cloudAttachmentKnowledge }
        set { withMutation(keyPath: \.cloudAttachmentKnowledge) { application.cloudAttachmentKnowledge = newValue } }
    }
    private struct AttachmentStateRefresh {
        let id: UUID
        let libraryRevision: UUID
        let lastKnownSource: AttachmentFileSource?
        var checkedApplication: CheckedApplicationRequest?
    }
    private struct PreparedAttachmentRecord {
        var url: URL
        var identity: PreparedAttachmentIdentity?
    }

    final class AttachmentCopyCapture {
        fileprivate let sourceRevision: UUID
        fileprivate let fileRevision: UUID
        fileprivate let originals: [UUID: SnipAttachment]
        fileprivate let owners: [UUID: Set<UUID>]
        fileprivate var admitted: Set<UUID> = []
        fileprivate var urls: [UUID: URL] = [:]
        fileprivate var invalidated = false

        fileprivate init(sourceRevision: UUID, fileRevision: UUID, snips: [Snip]) {
            self.sourceRevision = sourceRevision
            self.fileRevision = fileRevision
            originals = Dictionary(snips.flatMap(\.attachments).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
            var owners: [UUID: Set<UUID>] = [:]
            for snip in snips {
                for attachment in snip.attachments { owners[attachment.id, default: []].insert(snip.id) }
            }
            self.owners = owners
        }
    }

    private final class WeakAttachmentCopyCapture {
        weak var value: AttachmentCopyCapture?
        init(_ value: AttachmentCopyCapture) { self.value = value }
    }

    /// The preparations of one attachment that are running at the same time.
    private struct AttachmentPreparationGroup {
        let id = UUID()
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
    private enum BackupImportPhase {
        case idle
        case previewing(operation: UUID)
        case awaitingConfirmation(SavedSnipsImportPreview)
    }
    private var backupImport: BackupImportPhase = .idle
    var pendingImportPreview: SnipImportPreview? {
        guard case .awaitingConfirmation(let preview) = backupImport else { return nil }
        return preview.value
    }
    private(set) var selectedPage: LibraryPage {
        get { access(keyPath: \.selectedPage); return application.selectedPage }
        set { withMutation(keyPath: \.selectedPage) { application.selectedPage = newValue } }
    }
    private var selectionRevision: UInt64 {
        get { access(keyPath: \.selectionRevision); return application.selectionRevision }
        set { withMutation(keyPath: \.selectionRevision) { application.selectionRevision = newValue } }
    }
    private(set) var lastSelectedListID: UUID {
        get { access(keyPath: \.lastSelectedListID); return application.lastSelectedListID }
        set { withMutation(keyPath: \.lastSelectedListID) { application.lastSelectedListID = newValue } }
    }
    var pages: [LibraryPage] { [.clipboard] + lists.map { .list($0.id) } }
    private(set) var editingListID: UUID? {
        get { access(keyPath: \.editingListID); return application.editingListID }
        set { withMutation(keyPath: \.editingListID) { application.editingListID = newValue } }
    }
    private struct NewListOrigin {
        let page: LibraryPage
        let lastSelectedListID: UUID
    }
    private struct PendingNewList {
        let id: UUID
        let origin: NewListOrigin
    }
    private var pendingNewList: PendingNewList? {
        get { access(keyPath: \.pendingNewList); return application.pendingNewList }
        set { withMutation(keyPath: \.pendingNewList) { application.pendingNewList = newValue } }
    }
    var newListID: UUID? { pendingNewList?.id }
    var newListOriginPage: LibraryPage? { pendingNewList?.origin.page }
    var newListCancellationPage: LibraryPage {
        let origin = newListOriginPage ?? .list(SnipList.inboxID)
        return pages.contains(origin) ? origin : .list(SnipList.inboxID)
    }
    private var listDrafts: [UUID: InlineListDraft] {
        get { access(keyPath: \.listDrafts); return application.listDrafts }
        set { withMutation(keyPath: \.listDrafts) { application.listDrafts = newValue } }
    }
    private(set) var snipEditorDraft: SnipEditorDraft? {
        get { access(keyPath: \.snipEditorDraft); return application.snipEditorDraft }
        set { withMutation(keyPath: \.snipEditorDraft) { application.snipEditorDraft = newValue } }
    }
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
    var selectedSnipID: UUID? {
        get { access(keyPath: \.selectedSnipID); return application.selectedSnipID }
        set { withMutation(keyPath: \.selectedSnipID) { application.selectedSnipID = newValue } }
    }
    /// A gathering session runs from Select or the first gathered snip until it ends.
    /// A class, so readers of one field don't refresh when another changes.
    @MainActor @Observable fileprivate final class GatheringSession {
        let id: UUID
        private(set) var snipIDs: Set<UUID> = []
        /// Newest first. Snips gathered together keep their list order.
        private(set) var order: [UUID] = []
        var isExpanded = false

        init(id: UUID = UUID()) { self.id = id }

        func retaining(_ live: Set<UUID>) -> GatheringSession {
            let copy = GatheringSession(id: id)
            copy.snipIDs = snipIDs.intersection(live)
            copy.order = order.filter(live.contains)
            copy.isExpanded = isExpanded
            return copy
        }

        func replaceSnips(with ids: Set<UUID>, orderingNew: (Set<UUID>) -> [UUID]) {
            order = orderingNew(ids.subtracting(snipIDs)) + order.filter(ids.contains)
            snipIDs = ids
        }
    }
    private var gathering: GatheringSession? {
        get { access(keyPath: \.gathering); return application.gathering }
        set { withMutation(keyPath: \.gathering) { application.gathering = newValue } }
    }
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
    private var snackbarAndErrors: SnackbarAndErrorPresentation {
        get { access(keyPath: \.snackbarAndErrors); return application.snackbarAndErrors }
        set { withMutation(keyPath: \.snackbarAndErrors) { application.snackbarAndErrors = newValue } }
    }
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

    func retryPendingUndo(_ failure: AppFailure) {
        guard let undo = snackbarAndErrors.undoToRetry(for: failure) else { return }
        Task { await performToastActionNow(undo) }
    }

    func retryPendingUndoNow(_ failure: AppFailure) async {
        guard let undo = snackbarAndErrors.undoToRetry(for: failure) else { return }
        await performToastActionNow(undo)
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
        let initialTarget = SnipLibraryApplicationTarget.initial(for: library)
        session = SavedSnipsSession(
            library: initialTarget?.library ?? library,
            userActions: initialTarget == nil ? userActions : nil,
            userActionsFactory: userActionsFactory,
            recoveryScope: recoveryScope
        )
        self.cloudSyncHandler = cloudSyncHandler
        self.haptics = haptics
        self.diagnostics = diagnostics
        self.publishShareDestinations = publishShareDestinations
        application.source = initialTarget?.source
        application.target = initialTarget
        application.cloudAttachmentKnowledge = cloudSyncHandler == nil
            ? .known(.libraryFiles)
            : .unknown(lastKnown: nil, refresh: nil)
        application.snips = initialSnapshot.snips
        application.lists = initialSnapshot.lists
        application.attachmentURLs = initialSnapshot.attachmentURLs
        application.lastSelectedListID = SnipList.inboxID
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

    private func matchingSnips(in listID: UUID, query: String, from source: [Snip]) -> [Snip] {
        Snip.sorted(SnipFilter.apply(
            snips: source.filter { $0.listID == listID },
            query: query,
            completionFilter: completionFilter,
            originFilter: originFilter,
            sourceLabel: { $0.displaySourceLabel }
        ), by: sortMode)
    }

    func visibleSnips(in listID: UUID, matching query: String) -> [Snip] {
        let ordered = matchingSnips(in: listID, query: query, from: snips)
        return visibleSnips(from: ordered, matching: query, keepingEditor: snipEditorDraft?.original.id)
    }

    private func visibleSnips(from ordered: [Snip], matching query: String, keepingEditor editingID: UUID?) -> [Snip] {
        let limited = doneLimit.apply(to: ordered, completionFilter: completionFilter, query: query)
        guard let editingID,
              ordered.contains(where: { $0.id == editingID }),
              !limited.contains(where: { $0.id == editingID }) else { return limited }
        let visibleIDs = Set(limited.map(\.id)).union([editingID])
        return ordered.filter { visibleIDs.contains($0.id) }
    }

    private func reconcileDoneLimitSelection() {
        guard !selectedSnipIDs.isEmpty || selectedSnipID != nil else { return }
        let retainedIDs = retainedSelectionIDs(in: snips, lists: lists, keepingEditor: snipEditorDraft?.original.id)
        replaceGatheredSnips(with: selectedSnipIDs.intersection(retainedIDs))
        if let selectedSnipID, !retainedIDs.contains(selectedSnipID) {
            self.selectedSnipID = nil
        }
    }

    private func retainedSelectionIDs(in snips: [Snip], lists: [SnipList], keepingEditor editingID: UUID?) -> Set<UUID> {
        var retainedIDs = Set(snips.map(\.id))
        if completionFilter == .all, doneLimit != .unlimited, searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for list in lists {
                let matching = matchingSnips(in: list.id, query: searchText, from: snips)
                let visible = visibleSnips(from: matching, matching: searchText, keepingEditor: editingID)
                // Gathering survives other filters; only the Done cap removes matching snips.
                retainedIDs.subtract(Set(matching.map(\.id)).subtracting(visible.map(\.id)))
            }
        }
        return retainedIDs
    }

    var canReorderVisibleSnips: Bool {
        snipEditorDraft == nil
            && visibleSnips.count == snips.filter { $0.listID == lastSelectedListID }.count
            && completionFilter == .all
            && originFilter == .all
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
        await waitForAttachmentStateRefresh()
    }

    func setCheckedCatalogPublisher(_ publisher: ShareListCatalogPublisher?) {
        checkedCatalogPublisher = publisher
    }

    func publishCurrentCatalog(force: Bool = false) {
        if let target = application.target, let checkedCatalogPublisher {
            checkedCatalogPublisher.enqueue(application.lists, from: session, target: target)
        } else if application.source == nil {
            if let checkedCatalogPublisher { checkedCatalogPublisher.enqueue(application.lists, force: force) }
            else { publishShareDestinations?(application.lists) }
        }
    }

    @discardableResult
    func installCurrentSyncStatus(
        _ observation: SyncedContentCurrentSyncObservation,
        settings: SyncedContentSettingsModel, start: SyncedContentSyncStart
    ) throws -> Bool {
        guard observation.source == application.source, observation.matchesApplicationTarget(application.target),
              let publication = observation.publication,
              let prepared = settings.prepareCurrentState(observation, for: start) else { return false }
        let snapshot = SnipLibrarySnapshot(snips: application.snips, lists: application.lists,
            attachmentURLs: application.attachmentURLs)
        let matches = observation.matchesApplication(snapshot, after: application.publication, target: application.target, recovery: application.recoverySnapshot, files: application.files,
            attachmentStates: application.attachmentTransferStates)
        let closing = try publication.beginApplication()
        guard !observation.settled || matches else { closing.finish(); return false }
        let installed = settings.installPreparedCurrentState(prepared, within: closing)
        if installed && matches { application.publication = publication }
        closing.finish()
        if installed { settings.notifyInstalledCurrentState(prepared) }
        if installed && matches, let checkedCatalogPublisher {
            checkedCatalogPublisher.enqueue(snapshot.lists, publication: publication)
        }
        return installed
    }

    var appliedSource: SnipLibraryReadSource? { application.source }

    func applyChecked(
        _ target: SnipLibraryApplicationTarget, completion: SyncApplicationCompletion? = nil
    ) async throws -> CheckedApplication {
        try await requestCheckedApplication(.target(target), completion: completion)
    }

    func loadChecked() async throws -> CheckedApplication {
        try await requestCheckedApplication(.load)
    }

    func replaceLibraryChecked(
        _ library: any SnipLibrary, recoveryScope: SnipRecoveryScope?
    ) async throws -> CheckedApplication {
        haptics.invalidatePendingFeedback()
        return try await requestCheckedApplication(.replace(library, recoveryScope))
    }

    private func requestCheckedApplication(
        _ request: CheckedApplicationRequest, completion: SyncApplicationCompletion? = nil
    ) async throws -> CheckedApplication {
        try Task.checkCancellation()
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<CheckedApplication, any Error>.makeStream()
        checkedApplicationWaiters[id] = continuation
        if let target = request.target { checkedApplicationTargets[id] = target }
        defer {
            checkedApplicationTargets.removeValue(forKey: id)
            checkedApplicationWaiters.removeValue(forKey: id)?.finish()
            discardUnownedApplicationCompletions()
        }
        if let target = request.target, let completion, applicationCompletions[ObjectIdentifier(target)] == nil {
            applicationCompletions[ObjectIdentifier(target)] = completion
        }
        let joinsTarget: Bool
        switch request {
        case .target(let target):
            joinsTarget = pendingCheckedApplication?.target === target
                || (activeApplicationTarget === target && pendingCheckedApplication == nil)
        case .load:
            joinsTarget = pendingCheckedApplication?.target != nil
                || (activeApplicationTarget != nil && pendingCheckedApplication == nil)
        case .replace:
            joinsTarget = false
        }
        if !joinsTarget {
            switch (pendingCheckedApplication, request) {
            case (.some(.replace(_, _)), .load):
                // An ordinary load follows the already requested replacement.
                break
            default:
                if let superseded = pendingCheckedApplication?.target, superseded !== activeApplicationTarget {
                    finishTargetWaiters(superseded, with: .failure(SnipLibraryReadPublicationError.revoked))
                    applicationCompletions.removeValue(forKey: ObjectIdentifier(superseded))
                }
                pendingCheckedApplication = request
            }
            discardUnownedApplicationCompletions()
            checkedApplicationResult = nil
            attachmentStateRefreshPending = true
            cloudAttachmentKnowledge = .unknown(
                lastKnown: cloudAttachmentKnowledge.lastKnownSource, refresh: nil)
            startAttachmentStateWorker()
        }
        var iterator = stream.makeAsyncIterator()
        let value = try await iterator.next()
        try Task.checkCancellation()
        guard let value else { throw CancellationError() }
        return value
    }

    private func discardUnownedApplicationCompletions() {
        var owned = Set(checkedApplicationTargets.values.map(ObjectIdentifier.init))
        if let activeApplicationTarget { owned.insert(ObjectIdentifier(activeApplicationTarget)) }
        if let target = pendingCheckedApplication?.target { owned.insert(ObjectIdentifier(target)) }
        applicationCompletions = applicationCompletions.filter { owned.contains($0.key) }
    }

    private func performCheckedApplication(
        _ request: CheckedApplicationRequest, refreshID: UUID
    ) async -> Result<SnipLibraryReadObservation, any Error> {
        do {
            let read = try await withSerializedMutation {
                let checked: (read: SnipLibraryReadObservation, recovery: SnipRecoverySnapshot)
                var replacement: SavedSnipsSession.PreparedApplication?
                let replacing: Bool
                switch request {
                case .load:
                    replacing = false
                    let value = try await session.checkedRead(sortedBy: sortMode)
                    checked = (value, try await session.checkedRecovery())
                case .target(let target):
                    isReplacingAttachmentSource = true
                    defer { isReplacingAttachmentSource = false }
                    let prepared = try await session.prepareLibraryReconciliation(target.library,
                        recoveryScope: target.recoveryScope, replacing: application.source, sortedBy: sortMode)
                    guard prepared.read.source == target.source else { throw SnipLibraryReadPublicationError.revoked }
                    replacing = prepared.replaced
                    replacement = prepared
                    checked = (prepared.read, prepared.recovery)
                case .replace(let library, let scope):
                    replacing = true
                    isReplacingAttachmentSource = true
                    defer { isReplacingAttachmentSource = false }
                    let prepared = try await session.prepareLibraryApplication(library, recoveryScope: scope, replacing: true, sortedBy: sortMode)
                    replacement = prepared
                    checked = (prepared.read, prepared.recovery)
                }
                try Task.checkCancellation()
                guard cloudAttachmentKnowledge.refresh == refreshID else { throw CancellationError() }
                try installCheckedApplication(checked.read, recovery: checked.recovery, replacing: replacing, sessionApplication: replacement)
                await replacement?.finishRetiredActions()
                return checked.read
            }
            return .success(read)
        } catch { return .failure(error) }
    }

    private func installCheckedApplication(
        _ read: SnipLibraryReadObservation, recovery: SnipRecoverySnapshot, replacing: Bool,
        sessionApplication: SavedSnipsSession.PreparedApplication? = nil
    ) throws {
        if read.source != nil, read.publication == nil { throw SnipLibraryReadPublicationError.revoked }
        let previous = application
        let snapshot = read.snapshot
        var prepared = application
        prepared.snips = snapshot.snips
        prepared.lists = snapshot.lists
        prepared.attachmentURLs = snapshot.attachmentURLs
        prepared.recoverySnapshot = recovery
        prepared.source = read.source
        prepared.target = read.target
        prepared.publication = read.publication
        prepared.files = read.files
        let changedExistingFiles: Bool
        if case .success(let before) = application.files, case .success(let after) = read.files {
            changedExistingFiles = before.contains { id, file in
                file.kind != nil && after[id].map { $0 != file } == true
            }
        } else { changedExistingFiles = false }
        prepared.preparedAttachments = replacing || changedExistingFiles ? [:] : retainedPreparedAttachments(in: snapshot)
        if changedExistingFiles { prepared.attachmentFileRevision = UUID() }
        if replacing {
            prepared.libraryRevision = UUID()
            prepared.attachmentFileRevision = UUID()
            prepared.selectedSnipID = nil
            prepared.snipEditorDraft = nil
            prepared.attachmentTransferStates = [:]
            prepared.snackbarAndErrors.endUndoWindow()
        }
        let liveLists = Set(snapshot.lists.map(\.id))
        let liveSnips = Set(snapshot.snips.map(\.id))
        if let draft = prepared.snipEditorDraft, !liveSnips.contains(draft.original.id) { prepared.snipEditorDraft = nil }
        if let id = prepared.editingListID, !liveLists.contains(id) { prepared.editingListID = nil; prepared.listDrafts[id] = nil }
        if let pending = prepared.pendingNewList, !liveLists.contains(pending.id) {
            prepared.listDrafts[pending.id] = nil
            prepared.pendingNewList = nil
        }
        if !liveLists.contains(prepared.lastSelectedListID) {
            prepared.lastSelectedListID = SnipList.inboxID
            if case .list = prepared.selectedPage, prepared.selectedPage != .list(SnipList.inboxID) {
                prepared.selectedPage = .list(SnipList.inboxID)
                prepared.selectionRevision &+= 1
            }
        }
        if prepared.selectedSnipID != nil || prepared.gathering?.snipIDs.isEmpty == false {
            let retainedIDs = retainedSelectionIDs(in: prepared.snips, lists: prepared.lists,
                keepingEditor: prepared.snipEditorDraft?.original.id)
            if let selected = prepared.selectedSnipID, !retainedIDs.contains(selected) { prepared.selectedSnipID = nil }
            if let gathered = prepared.gathering, !gathered.snipIDs.isSubset(of: retainedIDs) {
                prepared.gathering = gathered.retaining(retainedIDs)
            }
        }
        let closing = try read.publication?.beginApplication()
        do { try sessionApplication?.install(within: closing) } catch { closing?.finish(); throw error }
        application = prepared
        closing?.finish()
        if let draft = previous.snipEditorDraft, draft !== prepared.snipEditorDraft { draft.discard() }
        if replacing || changedExistingFiles { attachmentPreparations.removeAll() }
        for capture in attachmentCopyCaptures {
            if let capture = capture.value { updateAttachmentCopyValidity(capture, snips: snapshot.snips) }
        }
        notifyCheckedApplication()
        if let publication = read.publication, let checkedCatalogPublisher {
            checkedCatalogPublisher.enqueue(snapshot.lists, publication: publication)
        } else if read.source == nil {
            publishShareDestinations?(snapshot.lists)
        }
        withExtendedLifetime(previous) {}
    }

    private func notifyCheckedApplication() {
        withMutation(keyPath: \.snips) {}; withMutation(keyPath: \.lists) {}
        withMutation(keyPath: \.attachmentURLs) {}; withMutation(keyPath: \.recoverySnapshot) {}
        withMutation(keyPath: \.libraryRevision) {}; withMutation(keyPath: \.attachmentFileRevision) {}
        withMutation(keyPath: \.selectedSnipID) {}; withMutation(keyPath: \.snipEditorDraft) {}
        withMutation(keyPath: \.lastSelectedListID) {}; withMutation(keyPath: \.selectedPage) {}
        withMutation(keyPath: \.selectionRevision) {}; withMutation(keyPath: \.editingListID) {}
        withMutation(keyPath: \.listDrafts) {}; withMutation(keyPath: \.pendingNewList) {}
        withMutation(keyPath: \.gathering) {}; withMutation(keyPath: \.preparedAttachments) {}
        withMutation(keyPath: \.attachmentTransferStates) {}; withMutation(keyPath: \.cloudAttachmentKnowledge) {}
        withMutation(keyPath: \.snackbarAndErrors) {}
    }

    func replaceLibrary(
        _ library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope?
    ) async {
        haptics.invalidatePendingFeedback()
        let revision = await withSerializedMutation {
            isReplacingAttachmentSource = true
            invalidateAttachmentSource()
            clearPendingUndoToast()
            if let snipEditorDraft { finishInlineSnipEdit(snipEditorDraft) }
            selectedSnipID = nil
            let state = await session.replaceLibrary(
                library,
                recoveryScope: recoveryScope,
                sortedBy: sortMode
            )
            libraryRevision = UUID()
            invalidateAttachmentSource()
            isReplacingAttachmentSource = false
            apply(state)
            return libraryRevision
        }
        await waitForAttachmentStateRefresh()
        guard libraryRevision == revision, !isReplacingAttachmentSource else { return }
        // A prepare can finish during the status read. This switch must end without one.
        invalidatePreparedAttachments()
    }

    @discardableResult
    func resolveRecovery(_ id: UUID, choice: SnipRecoveryChoice) async -> Bool {
        await withUserMutation { _ in
            await resolveRecoveryUnlocked(id, choice: choice)
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
            let unfinishedIDs = Set(snips.lazy.filter {
                versions[$0.id] == $0.updatedAt && !$0.isPinned && !$0.isDone
            }.map(\.id))
            guard !unfinishedIDs.isEmpty else { return .unchanged }
            let changed = await setDoneUnlocked(
                ids: unfinishedIDs,
                done: true,
                feedbackInteraction: nil,
                copyToast: copyToast,
                expectation: SnipLibraryExpectation(expectedCompletionSnips: snips.filter { unfinishedIDs.contains($0.id) })
            )
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

    func closeSnackbar(_ snackbar: AppToast) {
        snackbarAndErrors.closeSnackbar(id: snackbar.id)
    }

    func performToastAction(_ presentedToast: AppToast) {
        Task { await performToastActionNow(presentedToast) }
    }

    func performToastActionNow(_ presentedToast: AppToast) async {
        switch presentedToast.action {
        case .undoDelete:
            await withUserMutation { interaction in
                await restoreDeletion(presentedToast, feedbackInteraction: interaction)
            }
        case .undoDone:
            await withUserMutation { interaction in
                let priorUndoFailureID = snackbarAndErrors.retryUndoFailure?.id
                do {
                    guard let update = try await session.restoreDone(token: presentedToast.id, sortedBy: sortMode) else {
                        expireUnavailableUndoRetry(token: presentedToast.id, operation: "snip.undo_done")
                        return
                    }
                    snackbarAndErrors.undoSucceeded(presentedToast)
                    clearFailure(for: "snip.undo_done")
                    apply(update.snapshot)
                    haptics.emit(.reopened, for: interaction)
                    scheduleCloudSync()
                } catch {
                    retainUndoFailure(error, operation: "snip.undo_done", toast: presentedToast,
                                      replacingDetailsFor: priorUndoFailureID)
                    haptics.emit(.error, for: interaction)
                }
            }
        case .showErrorDetails(let id):
            snackbarAndErrors.showLatestErrorDetails(ifLatestIs: id)
        case nil:
            break
        }
    }

    func dismissToast(_ presentedToast: AppToast) {
        Task {
            await session.withExclusiveAccess { session in
                switch presentedToast.action {
                case .undoDelete:
                    await session.discardDeletion(token: presentedToast.id, sortedBy: sortMode)
                case .undoDone:
                    await session.discardDone(token: presentedToast.id)
                default:
                    break
                }
            }
            snackbarAndErrors.closeSnackbar(id: presentedToast.id)
        }
    }

    private func loadUnlocked() async {
        apply(await session.state(sortedBy: sortMode))
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
            clearPendingUndoToast()
            apply(state)
            scheduleCloudSync()
            return true
        } catch {
            presentError(error, operation: "recovery.resolve")
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

    func beginAttachmentCopy(snips: [Snip]) -> AttachmentCopyCapture {
        let capture = AttachmentCopyCapture(sourceRevision: libraryRevision,
            fileRevision: attachmentFileRevision, snips: snips)
        for requested in snips {
            guard let owner = self.snips.first(where: { $0.id == requested.id }),
                  requested.attachments.allSatisfy({ owner.attachments.contains($0) }) else {
                capture.invalidated = true
                break
            }
        }
        updateAttachmentCopyValidity(capture, snips: self.snips)
        attachmentCopyCaptures.removeAll { $0.value == nil }
        attachmentCopyCaptures.append(WeakAttachmentCopyCapture(capture))
        return capture
    }

    func prepareAttachmentCopy(
        _ attachmentID: UUID, in capture: AttachmentCopyCapture,
        onFailure: ((String) -> Void)?, onCancellation: (() -> Void)?
    ) async {
        updateAttachmentCopyValidity(capture, snips: snips)
        guard !capture.invalidated, !Task.isCancelled,
              let original = capture.originals[attachmentID],
              snips.flatMap(\.attachments).contains(original) else {
            onCancellation?()
            return
        }
        capture.admitted.insert(attachmentID)
        capture.urls[attachmentID] = await prepareAttachment(attachmentID, for: .copy,
            onFailure: onFailure, onCancellation: onCancellation)
    }

    func validatedAttachmentCopyURLs(_ capture: AttachmentCopyCapture) -> [UUID: URL]? {
        updateAttachmentCopyValidity(capture, snips: snips)
        guard !capture.invalidated, !Task.isCancelled,
              capture.admitted == Set(capture.originals.keys) else { return nil }
        let live = Dictionary(snips.flatMap(\.attachments).map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        var urls: [UUID: URL] = [:]
        for id in capture.originals.keys {
            if live[id] != nil {
                urls[id] = attachmentURL(for: id)
            } else {
                clearRemovedAttachmentState(id)
                if capture.admitted.contains(id), let url = capture.urls[id], isAvailablePreparedAttachment(url) {
                    urls[id] = url
                }
            }
        }
        return urls
    }

    private func updateAttachmentCopyValidity(_ capture: AttachmentCopyCapture, snips: [Snip]) {
        guard !capture.invalidated else { return }
        guard !isReplacingAttachmentSource, libraryRevision == capture.sourceRevision,
              attachmentFileRevision == capture.fileRevision else {
            capture.invalidated = true
            return
        }
        let owners = Dictionary(snips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let live = Dictionary(snips.flatMap(\.attachments).map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        for (id, original) in capture.originals {
            if let current = live[id], current != original { capture.invalidated = true }
            for ownerID in capture.owners[id, default: []] {
                if let owner = owners[ownerID], !owner.attachments.contains(original) { capture.invalidated = true }
            }
        }
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
        guard !isReplacingAttachmentSource else {
            onCancellation?()
            return nil
        }
        let identity = preparedAttachmentIdentity(for: attachmentID)
        let owner = snips.first { $0.attachments.contains { $0.id == attachmentID } }
        let ownerID = owner?.id
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
        let groupID = group.id
        let sourceRevision = libraryRevision
        let fileRevision = attachmentFileRevision
        let copyAdmission = use == .copy ? owner.map { owner in
            var captured = owner
            captured.attachments = owner.attachments.filter { $0.id == attachmentID }
            return beginAttachmentCopy(snips: [captured])
        } : nil
        do {
            let url = try await cloudSyncHandler.prepareSyncedAttachment(attachmentID, for: use)
            guard !isReplacingAttachmentSource, libraryRevision == sourceRevision,
                  attachmentFileRevision == fileRevision else {
                onCancellation?()
                return nil
            }
            let currentIdentity = preparedAttachmentIdentity(for: attachmentID)
            if copyAdmission?.invalidated == true {
                if currentIdentity == nil { retireRemovedAttachmentPreparation(attachmentID, groupID: groupID) }
                else { finishAttachmentPreparation(attachmentID, outcome: .cancelled) }
                onCancellation?()
                return nil
            }
            if identity != nil, currentIdentity == nil {
                retireRemovedAttachmentPreparation(attachmentID, groupID: groupID)
                guard use == .copy, copyAdmission != nil, let ownerID, !snips.contains(where: { $0.id == ownerID }),
                      !Task.isCancelled, isAvailablePreparedAttachment(url) else {
                    onCancellation?()
                    return nil
                }
                return url
            }
            if let identity, identity != currentIdentity {
                finishAttachmentPreparation(attachmentID, outcome: .cancelled)
                onCancellation?()
                return nil
            }
            attachmentURLs[attachmentID] = url
            preparedAttachments[attachmentID] = PreparedAttachmentRecord(
                url: url,
                identity: identity ?? currentIdentity
            )
            finishAttachmentPreparation(attachmentID, outcome: .succeeded)
            return url
        } catch {
            guard !isReplacingAttachmentSource, libraryRevision == sourceRevision,
                  attachmentFileRevision == fileRevision else {
                onCancellation?()
                return nil
            }
            if identity != nil, preparedAttachmentIdentity(for: attachmentID) == nil {
                retireRemovedAttachmentPreparation(attachmentID, groupID: groupID)
                onCancellation?()
                return nil
            }
            if let identity, identity != preparedAttachmentIdentity(for: attachmentID) {
                finishAttachmentPreparation(attachmentID, outcome: .cancelled)
                onCancellation?()
                return nil
            }
            if error is CancellationError || Task.isCancelled {
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

    private func retireRemovedAttachmentPreparation(_ attachmentID: UUID, groupID: UUID) {
        guard var group = attachmentPreparations[attachmentID], group.id == groupID else { return }
        group.memberCount -= 1
        attachmentPreparations[attachmentID] = group.memberCount > 0 ? group : nil
        clearRemovedAttachmentState(attachmentID)
    }

    private func clearRemovedAttachmentState(_ attachmentID: UUID) {
        attachmentURLs[attachmentID] = nil
        preparedAttachments[attachmentID] = nil
        attachmentTransferStates[attachmentID] = nil
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
        preparedAttachments = retainedPreparedAttachments(in: snapshot)
    }

    private func retainedPreparedAttachments(in snapshot: SnipLibrarySnapshot) -> [UUID: PreparedAttachmentRecord] {
        let attachments = Dictionary(
            snapshot.snips.flatMap(\.attachments).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return preparedAttachments.filter { id, prepared in
            guard let attachment = attachments[id],
                  let identity = prepared.identity,
                  attachment.fileName == identity.fileName,
                  attachment.byteCount == identity.byteCount,
                  isAvailablePreparedAttachment(prepared.url) else { return false }
            return true
        }
    }

    private func invalidatePreparedAttachments() {
        attachmentFileRevision = UUID()
        preparedAttachments.removeAll()
        for (id, group) in attachmentPreparations {
            attachmentTransferStates[id] = group.reportedState
        }
        attachmentPreparations.removeAll()
    }

    private func invalidateAttachmentSource() {
        invalidatePreparedAttachments()
        cloudAttachmentKnowledge = .unknown(lastKnown: nil, refresh: nil)
        replaceAttachmentTransferStates(with: [:])
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
        guard let cloudSyncHandler, !isReplacingAttachmentSource else { return }
        let revision = libraryRevision
        do {
            try await cloudSyncHandler.clearDownloadedFiles()
            guard libraryRevision == revision, !isReplacingAttachmentSource else { return }
            invalidatePreparedAttachments()
            let state = await session.state(sortedBy: .chronological)
            guard libraryRevision == revision, !isReplacingAttachmentSource else { return }
            apply(state)
            await waitForAttachmentStateRefresh()
            guard libraryRevision == revision, !isReplacingAttachmentSource else { return }
            // A prepare can store a file during either await. Clearing must end without one.
            invalidatePreparedAttachments()
        } catch {
            guard libraryRevision == revision, !isReplacingAttachmentSource else { return }
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

    private func setDoneUnlocked(
        ids: Set<UUID>, done: Bool, feedbackInteraction: UUID?, copyToast: AppToast? = nil,
        expectation: SnipLibraryExpectation? = nil
    ) async -> Bool {
        let eligible = snips.filter { ids.contains($0.id) && !$0.isPinned }
        guard !eligible.isEmpty else { return false }
        let ids = Set(eligible.filter { $0.isDone != done }.map(\.id))
        guard !ids.isEmpty else { return true }
        do {
            let change = try await session.setDone(
                ids: ids, done: done, expectation: expectation, sortedBy: sortMode
            )
            guard change.didChange else {
                apply(change.update.snapshot)
                return true
            }
            clearPendingUndoToast()
            clearFailure(for: "snip.completion")
            clearFailure(for: "snip.completion_after_copy")
            apply(change.update.snapshot)
            if let undo = change.undo {
                snackbarAndErrors.show(copyToast?.addingDoneUndo(undo) ?? .markedDone(count: undo.count, id: undo.id))
            }
            haptics.emit(done ? .markedDone : .reopened, for: feedbackInteraction)
            recoverySnapshot = await session.refreshRecovery()
            scheduleCloudSync()
            return true
        } catch {
            if copyToast != nil {
                presentError(
                    String(localized: "Copied, but couldn’t mark Done. Try marking the snip Done again."),
                    operation: "snip.completion_after_copy",
                    diagnosticCode: diagnosticErrorCode(error)
                )
            } else {
                presentError(error, operation: "snip.completion")
            }
            haptics.emit(.error, for: feedbackInteraction)
            return false
        }
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

    private func restoreDeletion(_ presentedToast: AppToast, feedbackInteraction: UUID?) async {
        let token = presentedToast.id
        let priorUndoFailureID = snackbarAndErrors.retryUndoFailure?.id
        do {
            guard let update = try await session.restoreDeletion(
                token: token,
                sortedBy: sortMode
            ) else {
                expireUnavailableUndoRetry(token: token, operation: "snip.undo_delete")
                return
            }
            snackbarAndErrors.undoSucceeded(presentedToast)
            clearFailure(for: "snip.undo_delete")
            apply(update.snapshot)
            haptics.emit(.restored, for: feedbackInteraction)
            recoverySnapshot = await session.refreshRecovery()
            scheduleCloudSync()
        } catch {
            haptics.emit(.error, for: feedbackInteraction)
            retainUndoFailure(error, operation: "snip.undo_delete", toast: presentedToast,
                              replacingDetailsFor: priorUndoFailureID)
        }
    }

    private func retainUndoFailure(
        _ error: any Error, operation: StaticString, toast: AppToast,
        replacingDetailsFor priorFailureID: UUID?
    ) {
        presentError(error, operation: operation)
        snackbarAndErrors.retainUndoFailure(of: toast, movingDetailsFrom: priorFailureID)
    }

    private func deleteSnips(ids: Set<UUID>, feedbackInteraction: UUID?) async -> Bool {
        let ids = ids.intersection(snips.map(\.id))
        guard !ids.isEmpty else { return false }
        let count = ids.count
        let token = UUID()
        do {
            let result = try await session.deleteWithResult(
                ids: ids,
                token: token,
                sortedBy: sortMode
            )
            apply(result.update.snapshot)
            guard result.didChange else { return true }
            clearPendingUndoToast()
            clearFailure(for: "snip.delete")
            if let selectedSnipID, ids.contains(selectedSnipID) { self.selectedSnipID = nil }
            replaceGatheredSnips(with: selectedSnipIDs.subtracting(ids))
            snackbarAndErrors.show(.deleted(count: count, id: token))
            haptics.emit(.deleted, for: feedbackInteraction)
            recoverySnapshot = await session.refreshRecovery()
            scheduleCloudSync()
            return true
        } catch {
            presentError(error, operation: "snip.delete")
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
            let result = try await session.performUserCommandWithResult(
                command,
                sortedBy: sortMode
            )
            let update = result.update
            if result.didChange { clearPendingUndoToast() }
            clearFailure(for: String(describing: command.diagnosticOperation))
            apply(update.snapshot)
            if let feedback, result.didChange {
                haptics.emit(feedback, for: feedbackInteraction)
            }
            afterSuccess(update.outcome)
            recoverySnapshot = await session.refreshRecovery()
            scheduleCloudSync()
            return true
        } catch {
            presentError(error, operation: command.diagnosticOperation)
            haptics.emit(.error, for: feedbackInteraction)
            return false
        }
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

    private func expireUnavailableUndoRetry(token: UUID, operation: StaticString) {
        guard snackbarAndErrors.retainsUndo(token) else { return }
        let failure = AppFailure(
            message: String(localized: "Undo is no longer available because the snips changed."),
            operation: operation, diagnosticCode: "undo.unavailable"
        )
        diagnostics.record(.failure(operation: operation, errorCode: failure.code, visibility: .user))
        snackbarAndErrors.replaceRetryUndo(with: failure)
    }

    private func clearPendingUndoToast() {
        snackbarAndErrors.endUndoWindow()
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
        let operationID = UUID()
        backupImport = .previewing(operation: operationID)
        do {
            let preview = try await session.withExclusiveAccess { session in
                try Task.checkCancellation()
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                return try await session.previewImport(from: url)
            }
            guard isPreviewingBackupImport(operationID), !Task.isCancelled else {
                await session.withExclusiveAccess { session in
                    _ = await session.cancelImport(id: preview.id)
                }
                throw CancellationError()
            }
            backupImport = .awaitingConfirmation(preview)
        } catch {
            if isPreviewingBackupImport(operationID) {
                backupImport = .idle
            }
            if !(error is CancellationError) {
                diagnostics.record(.failure(operation: "backup.import_preview", error: error, visibility: .user))
            }
            throw error
        }
    }

    func cancelBackupImport() {
        let previous = backupImport
        backupImport = .idle
        guard case .awaitingConfirmation(let preview) = previous else { return }
        Task {
            await session.withExclusiveAccess { session in
                _ = await session.cancelImport(id: preview.id)
            }
        }
    }

    func confirmBackupImport() async throws {
        haptics.invalidatePendingFeedback()
        guard case .awaitingConfirmation(let preview) = backupImport else { return }
        backupImport = .idle
        let id = preview.id
        do {
            guard let (result, recovery) = try await session.withExclusiveAccess({ session in
                try Task.checkCancellation()
                return try await session.applyPendingImport(id: id, sortedBy: .chronological)
            }) else { throw SnipLibraryError.importChanged }
            clearPendingUndoToast()
            apply(result.snapshot)
            recoverySnapshot = recovery
        } catch {
            await session.withExclusiveAccess { session in
                _ = await session.cancelImport(id: id)
            }
            if !(error is CancellationError) {
                diagnostics.record(.failure(operation: "backup.import_apply", error: error, visibility: .user))
                await load()
            }
            throw error
        }
    }

    private func isPreviewingBackupImport(_ operation: UUID) -> Bool {
        guard case .previewing(let current) = backupImport else { return false }
        return current == operation
    }

    private func apply(_ state: SavedSnipsSessionState) {
        apply(state.library)
        recoverySnapshot = state.recovery
    }

    private func apply(_ snapshot: SnipLibrarySnapshot) {
        attachmentCopyCaptures.removeAll { $0.value == nil }
        for capture in attachmentCopyCaptures {
            if let capture = capture.value { updateAttachmentCopyValidity(capture, snips: snapshot.snips) }
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
        publishCurrentCatalog()
        requestAttachmentTransferStateRefresh()
    }

    private func requestAttachmentTransferStateRefresh() {
        guard let cloudSyncHandler else {
            cloudAttachmentKnowledge = .known(.libraryFiles)
            replaceAttachmentTransferStates(with: Dictionary(uniqueKeysWithValues:
                attachmentURLs.keys.map { ($0, .available) }
            ))
            return
        }
        let lastKnown = cloudAttachmentKnowledge.lastKnownSource
        cloudAttachmentKnowledge = .unknown(lastKnown: lastKnown, refresh: nil)
        attachmentStateRefreshPending = true
        if !checkedApplicationWaiters.isEmpty, pendingCheckedApplication == nil {
            pendingCheckedApplication = activeApplicationTarget.map(CheckedApplicationRequest.target) ?? .load
        }
        startAttachmentStateWorker()
    }

    private func startAttachmentStateWorker() {
        guard !isReplacingAttachmentSource, attachmentStateRefreshTask == nil else { return }
        let handler = cloudSyncHandler
        // One application/status owner and one coalesced follow-up, including required callers.
        attachmentStateRefreshTask = Task { [weak self, handler] in
            while var refresh = self?.beginAttachmentStateRefresh() {
                if let request = refresh.checkedApplication {
                    guard let result = await self?.performCheckedApplication(request, refreshID: refresh.id) else { break }
                    switch result {
                    case .failure(let error):
                        self?.failCheckedApplication(error, for: refresh)
                        await self?.finishCheckedPass(refresh)
                        continue
                    case .success(let read):
                        guard let updated = self?.checkedRefreshAfterApplication(refresh, read: read) else {
                            await self?.finishCheckedPass(refresh)
                            continue
                        }
                        refresh = updated
                        guard let handler else {
                            self?.completeHandlerFreeApplication(read, for: refresh)
                            await self?.finishCheckedPass(refresh)
                            continue
                        }
                        do {
                            let observed = try await handler.checkedAttachmentStates()
                            self?.receiveCheckedAttachmentStates(observed, read: read, for: refresh)
                        } catch {
                            self?.failCheckedApplication(error, for: refresh)
                        }
                        await self?.finishCheckedPass(refresh)
                        continue
                    }
                }
                guard let handler else { continue }
                let isActive: Bool
                do {
                    isActive = try await handler.isCloudSyncActive()
                } catch {
                    self?.failAttachmentStateRefresh(refresh, readingMode: true)
                    continue
                }
                guard self?.receiveCloudSyncMode(isActive, for: refresh) == true else { continue }
                do {
                    let states = try await handler.syncedAttachmentStates()
                    self?.receiveAttachmentTransferStates(states, for: refresh)
                } catch {
                    self?.failAttachmentStateRefresh(refresh, readingMode: false)
                }
            }
            self?.finishAttachmentStateRefresh()
        }
    }

    private func waitForAttachmentStateRefresh() async {
        guard attachmentStateRefreshTask != nil else { return }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        attachmentStateRefreshWaiters[id] = continuation
        defer { attachmentStateRefreshWaiters.removeValue(forKey: id)?.finish() }
        // Cancelling this caller ends its wait without cancelling the shared status read.
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    private func checkedRefreshAfterApplication(
        _ refresh: AttachmentStateRefresh, read: SnipLibraryReadObservation
    ) -> AttachmentStateRefresh? {
        guard cloudAttachmentKnowledge.refresh == refresh.id else { return nil }
        return AttachmentStateRefresh(id: refresh.id, libraryRevision: libraryRevision,
            lastKnownSource: refresh.lastKnownSource, checkedApplication: refresh.checkedApplication)
    }

    private func failCheckedApplication(_ error: any Error, for refresh: AttachmentStateRefresh) {
        guard isCurrentAttachmentStateRefresh(refresh) else { return }
        checkedApplicationResult = .failure(error)
        failAttachmentStateRefresh(refresh, readingMode: true)
    }

    private func completeHandlerFreeApplication(_ read: SnipLibraryReadObservation, for refresh: AttachmentStateRefresh) {
        guard isCurrentAttachmentStateRefresh(refresh) else { return }
        guard read.source?.storageMode != .iCloudSync else {
            failCheckedApplication(SnipLibraryError.transferUnsupported, for: refresh)
            return
        }
        cloudAttachmentKnowledge = .known(.libraryFiles)
        replaceAttachmentTransferStates(with: Dictionary(uniqueKeysWithValues: attachmentURLs.keys.map { ($0, .available) }))
        checkedApplicationResult = .success(CheckedApplication(read: read, attachments: nil))
    }

    private func receiveCheckedAttachmentStates(
        _ observation: SyncedAttachmentReadObservation, read: SnipLibraryReadObservation,
        for refresh: AttachmentStateRefresh
    ) {
        guard isCurrentAttachmentStateRefresh(refresh) else { return }
        do {
            guard observation.source == application.source,
                  observation.continuesApplication(read.publication),
                  observation.matchesApplicationTarget(application.target),
                  let publication = observation.publication else { throw SnipLibraryReadPublicationError.revoked }
            let previous = application
            var prepared = application
            prepared.publication = publication
            prepared.attachmentTransferStates = observation.states
            prepared.cloudAttachmentKnowledge = observation.source.storageMode == .localOnly
                ? .known(.libraryFiles) : .known(.iCloudSync(statesAreCurrent: true))
            if observation.source.storageMode == .localOnly {
                prepared.preparedAttachments = [:]
                prepared.attachmentFileRevision = UUID()
            } else {
                prepared.preparedAttachments = prepared.preparedAttachments.filter { id, _ in
                    guard let state = observation.states[id] else { return false }
                    return state != .failed
                }
            }
            let closing = try publication.beginApplication()
            application = prepared
            closing.finish()
            for id in attachmentPreparations.keys { attachmentPreparations[id]?.reportedState = observation.states[id] }
            withMutation(keyPath: \.attachmentTransferStates) {}
            withMutation(keyPath: \.cloudAttachmentKnowledge) {}
            withMutation(keyPath: \.preparedAttachments) {}
            withMutation(keyPath: \.attachmentFileRevision) {}
            withExtendedLifetime(previous) {}
            checkedCatalogPublisher?.enqueue(prepared.lists, publication: publication)
            checkedApplicationResult = .success(CheckedApplication(read: read, attachments: observation))
        } catch {
            failCheckedApplication(error, for: refresh)
        }
    }

    private func finishCheckedPass(_ refresh: AttachmentStateRefresh) async {
        guard let target = refresh.checkedApplication?.target else { return }
        guard let result = checkedApplicationResult else {
            if pendingCheckedApplication?.target !== target {
                finishTargetWaiters(target, with: .failure(SnipLibraryReadPublicationError.revoked))
                applicationCompletions.removeValue(forKey: ObjectIdentifier(target))
                activeApplicationTarget = nil
            }
            return
        }
        var completed = result
        if case .success(let applied) = result,
           let context = applicationCompletions[ObjectIdentifier(target)] {
            do { try await completeSyncApplication(applied, target: target, context: context) }
            catch { completed = .failure(error) }
        }
        applicationCompletions.removeValue(forKey: ObjectIdentifier(target))
        activeApplicationTarget = nil
        finishTargetWaiters(target, with: completed)
        checkedApplicationResult = completed
    }

    private func finishTargetWaiters(
        _ target: SnipLibraryApplicationTarget, with result: Result<CheckedApplication, any Error>
    ) {
        let matching = checkedApplicationTargets.filter { $0.value === target }
        for id in matching.keys {
            checkedApplicationTargets.removeValue(forKey: id)
            guard let continuation = checkedApplicationWaiters.removeValue(forKey: id) else { continue }
            switch result {
            case .success(let value): continuation.yield(value); continuation.finish()
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
    }

    private func completeSyncApplication(
        _ applied: CheckedApplication, target: SnipLibraryApplicationTarget, context: SyncApplicationCompletion
    ) async throws {
        guard let settings = context.settings else { throw CancellationError() }
        let prepared: SyncedContentSettingsModel.PreparedCurrentState?
        if let issue = context.stoppedIssue {
            prepared = settings.prepareStoppedCurrentState(issue, read: applied.read,
                attachments: applied.attachments, for: context.start)
        } else if let completed = context.removalCompleted {
            prepared = settings.prepareRemovalCurrentState(completed: completed, read: applied.read,
                attachments: applied.attachments, for: context.start)
        } else if context.enabling {
            prepared = settings.prepareEnabledCurrentState(read: applied.read, attachments: applied.attachments, for: context.start)
        } else { return }
        guard let prepared else { throw SnipLibraryReadPublicationError.revoked }
        guard application.source == target.source,
              let publication = applied.attachments?.publication ?? applied.read.publication else {
            throw SnipLibraryReadPublicationError.revoked
        }
        let closing = try publication.beginApplication()
        let installed = settings.installPreparedCurrentState(prepared, within: closing)
        closing.finish()
        guard installed else { throw SnipLibraryReadPublicationError.revoked }
        settings.notifyInstalledCurrentState(prepared)
        if context.stoppedIssue != nil {
            guard let clipboard = context.clipboard else { throw CancellationError() }
            clipboard.stop()
            await clipboard.resetAccountBinding()
        }
    }

    private func finishAttachmentStateRefresh() {
        attachmentStateRefreshTask = nil
        activeApplicationTarget = nil
        applicationCompletions.removeAll()
        guard !isReplacingAttachmentSource else { return }
        let waiters = Array(attachmentStateRefreshWaiters.values)
        attachmentStateRefreshWaiters.removeAll()
        for waiter in waiters { waiter.finish() }
        for target in Array(checkedApplicationTargets.values) {
            finishTargetWaiters(target, with: .failure(SnipLibraryReadPublicationError.revoked))
        }
        let checked = Array(checkedApplicationWaiters.values)
        checkedApplicationWaiters.removeAll()
        checkedApplicationTargets.removeAll()
        let result = checkedApplicationResult ?? .failure(CancellationError())
        checkedApplicationResult = nil
        for waiter in checked {
            switch result {
            case .success(let value): waiter.yield(value); waiter.finish()
            case .failure(let error): waiter.finish(throwing: error)
            }
        }
    }

    private func beginAttachmentStateRefresh() -> AttachmentStateRefresh? {
        guard !isReplacingAttachmentSource, attachmentStateRefreshPending, !Task.isCancelled else { return nil }
        attachmentStateRefreshPending = false
        let refresh = AttachmentStateRefresh(id: UUID(), libraryRevision: libraryRevision,
            lastKnownSource: cloudAttachmentKnowledge.lastKnownSource, checkedApplication: pendingCheckedApplication)
        pendingCheckedApplication = nil
        activeApplicationTarget = refresh.checkedApplication?.target
        if refresh.checkedApplication != nil { checkedApplicationResult = nil }
        cloudAttachmentKnowledge = .unknown(lastKnown: refresh.lastKnownSource, refresh: refresh.id)
        return refresh
    }

    private func isCurrentAttachmentStateRefresh(_ refresh: AttachmentStateRefresh) -> Bool {
        !Task.isCancelled && !isReplacingAttachmentSource && libraryRevision == refresh.libraryRevision
            && cloudAttachmentKnowledge.refresh == refresh.id
    }

    private func failAttachmentStateRefresh(_ refresh: AttachmentStateRefresh, readingMode: Bool) {
        guard isCurrentAttachmentStateRefresh(refresh) else { return }
        // A failed read keeps the last known states while iCloud is unavailable.
        if readingMode {
            if case .iCloudSync = refresh.lastKnownSource {
                cloudAttachmentKnowledge = .unknown(
                    lastKnown: .iCloudSync(statesAreCurrent: false), refresh: nil
                )
            } else {
                cloudAttachmentKnowledge = .unknown(lastKnown: refresh.lastKnownSource, refresh: nil)
            }
        } else {
            cloudAttachmentKnowledge = .known(.iCloudSync(statesAreCurrent: false))
        }
    }

    private func receiveCloudSyncMode(_ isActive: Bool, for refresh: AttachmentStateRefresh) -> Bool {
        guard isCurrentAttachmentStateRefresh(refresh) else { return false }
        guard isActive else {
            cloudAttachmentKnowledge = .known(.libraryFiles)
            invalidatePreparedAttachments()
            replaceAttachmentTransferStates(with: [:])
            return false
        }
        // With iCloud sync off, its empty transfer states were current.
        let lastStatesAreCurrent = switch refresh.lastKnownSource {
        case nil: false
        case .libraryFiles: true
        case .iCloudSync(let statesAreCurrent): statesAreCurrent
        }
        cloudAttachmentKnowledge = .readingStates(
            refresh: refresh.id, lastStatesAreCurrent: lastStatesAreCurrent
        )
        return true
    }

    private func receiveAttachmentTransferStates(
        _ states: [UUID: SyncedAttachmentTransferState], for refresh: AttachmentStateRefresh
    ) {
        guard isCurrentAttachmentStateRefresh(refresh) else { return }
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
        _ operation: @MainActor @Sendable () async throws -> Result
    ) async rethrows -> Result {
        try await session.withExclusiveAccess { _ in try await operation() }
    }

    private func scheduleCloudSync() {
        guard let cloudSyncHandler else { return }
        Task { await cloudSyncHandler.scheduleSyncAfterLocalChange() }
    }

    deinit {
        attachmentStateRefreshTask?.cancel()
        for waiter in attachmentStateRefreshWaiters.values { waiter.finish() }
        for waiter in checkedApplicationWaiters.values { waiter.finish(throwing: CancellationError()) }
    }

}
