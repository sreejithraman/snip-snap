import AppKit
import Combine
import Foundation
import SnipSnapCore
import SnipSnapPersistence
import UniformTypeIdentifiers

struct ArchiveAttachmentPreparationError: Error {
    let underlying: any Error
}

@MainActor
final class AppModel: ObservableObject {
    enum FailurePresentation {
        case automatic
        case detailsOnly
    }

    static let sortModeDefaultsKey = "snipSortMode"
    static let activeListDefaultsKey = "activeListID"
    static let listDraftsDefaultsKey = "listDrafts"
    static let appearanceDefaultsKey = "appAppearance"

    @Published private(set) var snips: [Snip] = []
    @Published private(set) var lists: [SnipList] = [.inbox]
    @Published private(set) var libraryRevision = UUID()
    @Published var activeListID: UUID
    @Published private(set) var isShowingClipboard = false
    @Published var clipboardViewOptions = ClipboardViewOptions()
    private enum SearchMode: Equatable {
        case closed
        case open(query: String)
    }

    @Published private var searchMode = SearchMode.closed
    var isSearchExpanded: Bool { searchMode != .closed }
    var query: String {
        get {
            guard case .open(let query) = searchMode else { return "" }
            return query
        }
        set {
            guard editingID == nil || newValue == query else { return }
            switch searchMode {
            case .open:
                searchMode = .open(query: newValue)
                if hasActiveQuery { reconcileSelection() } else { selection = [] }
            case .closed:
                guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                selection = []
                searchMode = .open(query: newValue)
            }
        }
    }
    @Published private var storedCompletionFilter: SnipCompletionFilter = .all
    var completionFilter: SnipCompletionFilter {
        get { storedCompletionFilter }
        set {
            guard editingID == nil || newValue == storedCompletionFilter else { return }
            storedCompletionFilter = newValue
            reconcileSelection()
        }
    }
    @Published private var storedOriginFilter: SnipOriginFilter = .all
    var originFilter: SnipOriginFilter {
        get { storedOriginFilter }
        set {
            guard editingID == nil || newValue == storedOriginFilter else { return }
            storedOriginFilter = newValue
            reconcileSelection()
        }
    }
    @Published private(set) var selectionState = SnipSelection.Update(selection: [], anchor: nil, focus: nil)
    var selection: Set<UUID> {
        get { selectionState.selection }
        set {
            let orderedIDs = filteredSnips.map(\.id)
            let ids = newValue.intersection(orderedIDs)
            let anchor = selectionState.anchor.flatMap { ids.contains($0) ? $0 : nil }
                ?? orderedIDs.first(where: ids.contains)
            let focus = selectionState.focus.flatMap { ids.contains($0) ? $0 : nil } ?? anchor
            selectionState = .init(selection: ids, anchor: anchor, focus: focus)
        }
    }

    func applySelection(_ update: SnipSelection.Update) {
        selectionState = update
    }

    func reconcileSelection() {
        selection = selection
    }

    func selectSnip(_ id: UUID, modifiers: SnipSelection.Modifiers) {
        applySelection(SnipSelection.click(
            id, orderedIDs: filteredSnips.map(\.id), selection: selection,
            anchor: selectionState.anchor, focus: selectionState.focus, modifiers: modifiers
        ))
    }
    private struct InlineEdit {
        let sessionID: UUID
        let snipID: UUID
        let origin: (list: SnipList, index: Int)?
        var attachments: [URL]
    }

    private enum InlineEditor {
        case closed
        case editing(InlineEdit)
        case saving(InlineEdit)

        var edit: InlineEdit? {
            switch self {
            case .closed: nil
            case .editing(let edit), .saving(let edit): edit
            }
        }

        mutating func updateEdit(_ update: (inout InlineEdit) -> Void) {
            switch self {
            case .closed:
                return
            case .editing(var edit):
                update(&edit)
                self = .editing(edit)
            case .saving(var edit):
                update(&edit)
                self = .saving(edit)
            }
        }
    }

    @Published private var inlineEditor = InlineEditor.closed
    private var pendingEditOpening: (snipID: UUID, request: UUID)?
    var editingID: UUID? { inlineEditor.edit?.snipID }
    var inlineEditSessionID: UUID? { inlineEditor.edit?.sessionID }
    var inlineEditAttachments: [URL] { inlineEditor.edit?.attachments ?? [] }
    var isSavingInlineEdit: Bool {
        guard case .saving = inlineEditor else { return false }
        return true
    }

    func cancelEditing() {
        guard case .editing = inlineEditor else { return }
        closeInlineEditor()
    }

    func addInlineEditAttachments(_ urls: [URL], to sessionID: UUID) {
        guard case .editing(var edit) = inlineEditor, edit.sessionID == sessionID else { return }
        edit.attachments.append(
            contentsOf: PanelFileDropValidation.newFiles(in: urls, excluding: edit.attachments)
        )
        inlineEditor = .editing(edit)
    }

    func removeInlineEditAttachment(_ url: URL, from sessionID: UUID) {
        guard inlineEditSessionID == sessionID else { return }
        inlineEditor.updateEdit { edit in edit.attachments.removeAll { $0 == url } }
    }

    /// Returns true only when this call saved and closed its own edit session.
    func saveInlineEdit(content: String, in sessionID: UUID) async -> Bool {
        guard case .editing(let edit) = inlineEditor, edit.sessionID == sessionID else { return false }
        inlineEditor = .saving(edit)
        let snipID = edit.snipID
        let attachmentURLs = edit.attachments
        let result: Result<Void, Error>? = await withCommandLock {
            guard savingEdit(sessionID) != nil else { return nil }
            return await performMutationUnlocked {
                try await performUpdate(
                    id: snipID, content: content,
                    attachmentURLs: attachmentURLs, expectedUpdatedAt: nil
                )
            }
        }
        guard let result else { return false }
        switch result {
        case .failure(let error):
            presentError(error, operation: "snip.update")
            if let current = savingEdit(sessionID) {
                inlineEditor = .editing(current)
            }
            return false
        case .success:
            clearFailure(for: "snip.update")
            guard savingEdit(sessionID) != nil else { return false }
            closeInlineEditor()
            return true
        }
    }

    private func savingEdit(_ sessionID: UUID) -> InlineEdit? {
        guard case .saving(let edit) = inlineEditor, edit.sessionID == sessionID else { return nil }
        return edit
    }

    private func openInlineEdit(_ snip: Snip) {
        pendingEditOpening = nil
        let originIndex = lists.firstIndex(where: { $0.id == snip.listID })
        inlineEditor = .editing(InlineEdit(
            sessionID: UUID(),
            snipID: snip.id,
            origin: originIndex.map { (list: lists[$0], index: $0) },
            attachments: snip.attachments.compactMap { attachmentURL(for: $0) }
        ))
        reconcileActiveList()
    }

    private func closeInlineEditor() {
        guard editingID != nil else { return }
        inlineEditor = .closed
        reconcileActiveList()
        reconcileSelection()
    }

    @Published var snackbarAndErrors = SnackbarAndErrorPresentation()
    var toast: AppToast? { snackbarAndErrors.snackbar }
    var presentedError: String? { snackbarAndErrors.presentedFailure?.message }
    var presentedErrorTitle: String? { snackbarAndErrors.presentedTitle }
    var latestFailure: AppFailure? { snackbarAndErrors.latestFailure }
    var errorDetails: AppFailure? { snackbarAndErrors.errorDetails }
    var inlineFailure: AppFailure? { snackbarAndErrors.inlineFailure }
    var pendingUndoFailure: AppFailure? { snackbarAndErrors.pendingUndoFailure }

    var canRetryErrorAction: Bool {
        dialogFailure.map { snackbarAndErrors.undoToRetry(for: $0) != nil } ?? false
    }

    var errorRetryAction: (() -> Void)? {
        guard canRetryErrorAction, let failure = dialogFailure else { return nil }
        return { [weak self] in self?.retryPendingUndo(failure) }
    }

    var dialogFailure: AppFailure? {
        if let errorDetails { return errorDetails }
        guard let presented = snackbarAndErrors.presentedFailure, presented.surface == .dialog else { return nil }
        return presented
    }
    @Published private(set) var latestAddedSnipID: UUID?
    @Published private(set) var doneLimit: SnipDoneLimit
    @Published private(set) var sortMode: SnipSortMode
    @Published private(set) var appearance: AppAppearance
    @Published var recoverySnapshot: SnipRecoverySnapshot = .empty
    @Published var legacyDraftCount = 0
    @Published var backupImport = BackupImportPresentation()
    var pendingImportPreview: SavedSnipsImportPreview? { backupImport.preview }
    @Published var clipboardCopyPulse: ClipboardCopyPulse?
    @Published private(set) var cliScopeChangeInProgress = false
    private(set) var cliMutationInProgress = false
    var cliDialogIsPresented: @MainActor () -> Bool = { false }

    var isCLIInteractionReserved: Bool { cliScopeChangeInProgress || cliMutationInProgress }

    func beginCLIScopeChange() throws {
        guard !isCLIInteractionReserved else { throw SnipLibraryError.modeTransitionInProgress }
        guard editingID == nil, !cliDialogIsPresented() else {
            throw SnipCLIRequestError.editingInProgress
        }
        cliScopeChangeInProgress = true
    }

    func endCLIScopeChange() { cliScopeChangeInProgress = false }

    func beginCLIMutation() throws {
        guard !isCLIInteractionReserved else { throw SnipLibraryError.modeTransitionInProgress }
        guard !cliDialogIsPresented() else { throw SnipCLIRequestError.editingInProgress }
        cliMutationInProgress = true
    }

    func endCLIMutation() { cliMutationInProgress = false }

    func enterSearch() {
        guard editingID == nil, searchMode == .closed else { return }
        selection = []
        searchMode = .open(query: "")
    }

    func exitSearch() {
        guard editingID == nil, searchMode != .closed else { return }
        selection = []
        searchMode = .closed
    }

    var restingFocusTarget: PanelFocusTarget {
        isSearchExpanded ? .search : (isShowingClipboard ? .clipboard : .list)
    }

    var focusTargetAfterInlineEdit: PanelFocusTarget {
        guard isSearchExpanded else { return restingFocusTarget }
        return filteredSnips.isEmpty && clipboardSearchMatches.isEmpty ? .search : .list
    }

    var hasActiveQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSelectVisibleSnips: Bool {
        guard !filteredSnips.isEmpty else { return false }
        return isSearchExpanded ? hasActiveQuery : !isShowingClipboard
    }

    func canReorder(ids: Set<UUID>) -> Bool {
        guard !hasActiveQuery,
              completionFilter == .all,
              originFilter == .all,
              !ids.isEmpty,
              !snips.contains(where: { ids.contains($0.id) && $0.isPinned }) else { return false }
        let listIDs = Set(snips.filter { ids.contains($0.id) }.map(\.listID))
        guard listIDs.count == 1, let listID = listIDs.first else { return false }
        return filteredSnips(in: listID).count == snips.filter { $0.listID == listID }.count
    }

    let session: SavedSnipsSession
    private let attachmentPreparation: AttachmentPreparationCoordinator
    private let diagnostics: AppDiagnosticRecorder
    private var cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private let defaults: UserDefaults
    let composerDrafts: ComposerDraftStore

    /// Routes composer text for lists that left the library.
    private struct ComposerRedirection {
        private enum DeletedList {
            /// Deleted in this draft scope. Its draft text moved to the end of Inbox at
            /// `inboxRevision`; later text from its composer replaces that tail.
            case redirected(text: String, inboxRevision: UInt64)
            /// Left with the previous draft scope. Its composer no longer writes.
            case retired
        }

        /// A list with no entry owns no Inbox tail, so its redirected text appends.
        private var deletedLists: [UUID: DeletedList] = [:]
        private var inboxRevision: UInt64 = 0

        func isRetired(_ listID: UUID) -> Bool {
            if case .retired = deletedLists[listID] { true } else { false }
        }

        mutating func inboxChanged() { inboxRevision &+= 1 }

        mutating func listsReturned(_ liveIDs: Set<UUID>) {
            deletedLists = deletedLists.filter { !liveIDs.contains($0.key) }
        }

        mutating func listDeleted(_ listID: UUID, movedText: String) {
            inboxChanged()
            guard !movedText.isEmpty else { return }
            deletedLists[listID] = .redirected(text: movedText, inboxRevision: inboxRevision)
        }

        /// Returns the new Inbox text, or nil when Inbox keeps its text.
        mutating func redirect(_ text: String, from listID: UUID, inboxText: String) -> String? {
            var previous = ""
            var ownsInboxTail = false
            if case .redirected(let redirectedText, let revision) = deletedLists[listID] {
                previous = redirectedText
                ownsInboxTail = revision == inboxRevision
            }
            guard text != previous else { return nil }
            var updated: String?
            if ownsInboxTail, !previous.isEmpty, inboxText.hasSuffix(previous) {
                var base = String(inboxText.dropLast(previous.count))
                if base.hasSuffix("\n\n") { base.removeLast(2) }
                updated = base + (base.isEmpty || text.isEmpty ? "" : "\n\n") + text
            } else if !text.isEmpty {
                updated = inboxText + (inboxText.isEmpty ? "" : "\n\n") + text
            }
            inboxChanged()
            deletedLists[listID] = .redirected(text: text, inboxRevision: inboxRevision)
            return updated
        }

        mutating func switchScope(retiring listIDs: Set<UUID>) {
            deletedLists = Dictionary(uniqueKeysWithValues: listIDs.map { ($0, DeletedList.retired) })
            inboxChanged()
        }
    }

    private var composerRedirection = ComposerRedirection()
    private let preparePasteboardExport: @Sendable (String, [URL]) async throws
        -> SnipPasteboardExport
    private let publishShareDestinations: (([SnipList]) -> Void)?
    private let clipboardWrites = ClipboardWriteSequence()
    private var initialLoadTask: Task<Void, Never>?
    let clipboardHistory: ClipboardHistory

    var filteredSnips: [Snip] {
        filteredSnips(in: activeListID)
    }

    var displayedLists: [SnipList] {
        guard let origin = inlineEditor.edit?.origin,
              !lists.contains(where: { $0.id == origin.list.id }) else { return lists }
        var displayed = lists
        displayed.insert(origin.list, at: min(origin.index, displayed.count))
        return displayed
    }

    func snipListSnapshot(in listID: UUID) -> SnipListSnapshot {
        SnipListSnapshot(
            visibleSnips: filteredSnips(in: listID), allSnips: snips,
            lists: displayedLists, selection: selection,
            keepsEmptyListID: hasActiveQuery ? nil : listID,
            attachmentURL: attachmentURL
        )
    }

    func filteredSnips(in listID: UUID) -> [Snip] {
        let filtered = SnipFilter.apply(
            snips: hasActiveQuery ? snips : snips.filter { $0.listID == listID },
            query: query,
            completionFilter: hasActiveQuery ? .all : completionFilter,
            originFilter: originFilter,
            listNames: Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.name) }),
            sourceLabel: { $0.displaySourceLabel }
        )
        let matches = doneLimit.apply(to: filtered, completionFilter: completionFilter, query: query)
        let rendered: [Snip]
        if let editingID, let origin = inlineEditor.edit?.origin {
            let matchingIDs = Set(matches.map(\.id))
            // Moving the mounted row would discard its draft and temporary attachments.
            rendered = snips.compactMap { snip in
                if snip.id == editingID {
                    var editor = snip
                    editor.listID = origin.list.id
                    return editor
                }
                return matchingIDs.contains(snip.id) ? snip : nil
            }
        } else {
            rendered = matches
        }
        guard hasActiveQuery else {
            return rendered.filter { $0.listID == listID }
        }
        let matchesByList = Dictionary(grouping: rendered, by: \.listID)
        return displayedLists.flatMap { matchesByList[$0.id] ?? [] }
    }

    var selectedSnips: [Snip] {
        let selected = selection
        return snips.filter { selected.contains($0.id) }
    }

    var clipboardSearchMatches: [ClipboardEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return clipboardHistory.entries.filter {
            $0.searchText.localizedCaseInsensitiveContains(needle)
        }
    }

    var activeList: SnipList {
        displayedLists.first(where: { $0.id == activeListID }) ?? .inbox
    }

    func attachmentURL(for attachment: SnipAttachment) -> URL? {
        attachmentPreparation.cachedURL(for: attachment)
    }

    init(
        library: any SnipLibrary,
        defaults: UserDefaults = .standard,
        clipboardHistory: ClipboardHistory? = nil,
        initialError: String? = nil,
        recoveryScope: SnipRecoveryScope? = nil,
        cloudSyncHandler: (any OptionalCloudSyncHandling)? = nil,
        userActions: (any SnipLibraryUserActions)? = nil,
        userActionsFactory: @escaping SnipLibraryUserActionsFactory = { DirectSnipLibraryUserActions(library: $0) },
        preparePasteboardExport: @escaping @Sendable (String, [URL]) async throws
            -> SnipPasteboardExport = {
            try await SnipPasteboardExport.preparingClipboardExport(
                text: $0,
                attachmentURLs: $1
            )
        },
        diagnostics: AppDiagnosticRecorder = AppDiagnosticRecorder.live,
        publishShareDestinations: (([SnipList]) -> Void)? = nil
    ) {
        self.defaults = defaults
        composerDrafts = ComposerDraftStore(
            defaults: defaults,
            textDefaultsKey: Self.listDraftsDefaultsKey,
            scope: recoveryScope?.rawValue ?? "local"
        )
        self.clipboardHistory = clipboardHistory ?? ClipboardHistory()
        activeListID = defaults.string(forKey: Self.activeListDefaultsKey)
            .flatMap(UUID.init(uuidString:)) ?? SnipList.inboxID
        doneLimit = SnipDoneLimit.load(from: defaults)
        sortMode = SnipSortMode(
            rawValue: defaults.string(forKey: Self.sortModeDefaultsKey) ?? ""
        ) ?? .chronological
        appearance = AppAppearance(
            rawValue: defaults.string(forKey: Self.appearanceDefaultsKey) ?? ""
        ) ?? .system
        session = SavedSnipsSession(
            library: library,
            userActions: userActions,
            userActionsFactory: userActionsFactory,
            recoveryScope: recoveryScope
        )
        attachmentPreparation = AttachmentPreparationCoordinator(
            cloudSyncHandler: cloudSyncHandler
        )
        self.cloudSyncHandler = cloudSyncHandler
        self.preparePasteboardExport = preparePasteboardExport
        self.diagnostics = diagnostics
        self.publishShareDestinations = publishShareDestinations
        legacyDraftCount = composerDrafts.unattributedLegacyDrafts().count
        presentError(
            initialError,
            operation: "app.startup",
            diagnosticCode: "presentation.startup"
        )
        initialLoadTask = Task { [weak self] in
            await self?.reload()
        }
    }

    func presentError(
        _ error: any Error,
        operation: StaticString = "app.user_action",
        presentation: FailurePresentation = .automatic
    ) {
        let operationName = String(describing: operation)
        let message = error.localizedDescription
        let title = (error as? SnipLibraryError) == .duplicateList
            ? String(localized: "Name Already Used") : nil
        if shouldRecordPresentedFailure(operationName, message: message, title: title) {
            diagnostics.record(.failure(operation: operation, error: error, visibility: .user))
        }
        let failure = AppFailure(error: error, operation: operation, title: title)
        if case .detailsOnly = presentation {
            snackbarAndErrors.record(failure)
        } else {
            snackbarAndErrors.present(failure, title: title)
        }
    }

    func presentError(
        _ message: String?,
        title: String? = nil,
        operation: StaticString = "app.user_action",
        diagnosticCode: String = "presentation.message",
        presentation: FailurePresentation = .automatic
    ) {
        let operationName = String(describing: operation)
        if let message,
           shouldRecordPresentedFailure(operationName, message: message, title: title) {
            diagnostics.record(.failure(
                operation: operation,
                errorCode: diagnosticCode,
                visibility: .user
            ))
        }
        guard let message else {
            snackbarAndErrors.hidePresentedFailure()
            return
        }
        let failure = AppFailure(message: message, title: title, operation: operation, diagnosticCode: diagnosticCode)
        if case .detailsOnly = presentation {
            snackbarAndErrors.record(failure)
        } else {
            snackbarAndErrors.present(failure, title: title)
        }
    }

    func showLatestErrorDetails() {
        snackbarAndErrors.showLatestErrorDetails()
    }

    func showErrorDetails(_ failure: AppFailure) {
        snackbarAndErrors.showErrorDetails(failure)
    }

    func dismissErrorDetails(_ failure: AppFailure? = nil) {
        snackbarAndErrors.closeErrorDetails(failure)
    }

    func clearFailure(for operation: StaticString) {
        guard latestFailure?.operation == String(describing: operation) else { return }
        snackbarAndErrors.resolveLatestFailure()
    }

    private func dismissCopyFailure(matching id: UUID?) {
        guard let id, let failure = latestFailure, failure.id == id,
              ["attachment.prepare", "clipboard.export", "clipboard.write"].contains(failure.operation)
        else { return }
        snackbarAndErrors.resolveLatestFailure()
    }

    private func shouldRecordPresentedFailure(
        _ operation: String,
        message: String,
        title: String?
    ) -> Bool {
        guard operation == "attachment.prepare",
              let presented = snackbarAndErrors.presentedFailure else { return true }
        return presented.operation != operation || presented.message != message || presentedErrorTitle != title
    }

    func dismissPresentedError() {
        snackbarAndErrors.dismissPresentedFailure()
    }

    func setCloudSyncHandler(_ handler: (any OptionalCloudSyncHandling)?) {
        cloudSyncHandler = handler
        attachmentPreparation.setCloudSyncHandler(handler)
    }

    func prepareAttachments(
        _ attachments: [SnipAttachment],
        for use: SyncedAttachmentUse
    ) async throws -> [UUID: URL] {
        try await attachmentPreparation.prepare(attachments, for: use)
    }

    func prepareAttachmentPreview(
        _ attachments: [SnipAttachment],
        selected: SnipAttachment
    ) async throws -> (urls: [URL], selectedURL: URL)? {
        try await attachmentPreparation.preparePreview(attachments, selected: selected)
    }

    @discardableResult
    func prepareAttachmentsForExternalDrag(snipIDs: [UUID]) async -> Bool {
        let ids = Set(snipIDs)
        let attachments = snips
            .filter { ids.contains($0.id) }
            .flatMap(\.attachments)
        do {
            _ = try await prepareAttachments(attachments, for: .export)
            return true
        } catch is CancellationError {
            return false
        } catch {
            presentError(error, operation: "attachment.prepare")
            return false
        }
    }

    func waitForInitialLoad() async {
        await initialLoadTask?.value
    }

    func reload() async {
        await withCommandLock { await reloadUnlocked() }
    }

    func replaceLibrary(
        _ library: any SnipLibrary,
        recoveryScope: SnipRecoveryScope?
    ) async {
        await withCommandLock {
            clearPendingUndoToast()
            selection = []
            let newDraftScope = recoveryScope?.rawValue ?? "local"
            let scopeChanged = composerDrafts.scope != newDraftScope
            if recoveryScope == nil || scopeChanged {
                closeInlineEditor()
            }
            let previousListIDs = Set(lists.map(\.id))
            let state = await session.replaceLibrary(
                library,
                recoveryScope: recoveryScope,
                sortedBy: sortMode
            )
            if scopeChanged {
                composerDrafts.switchScope(to: newDraftScope)
            }
            apply(state)
            libraryRevision = UUID()
            let currentListIDs = Set(lists.map(\.id))
            if scopeChanged {
                composerRedirection.switchScope(retiring: previousListIDs.subtracting(currentListIDs))
            }
            await reloadUnlocked()
        }
    }

    func createBackup(at url: URL) async throws {
        let archive = try await session.withExclusiveAccess { session in
            try await session.archive()
        }
        try await writeBackup(archive, at: url)
    }

    func writeBackup(_ archive: SnipLibraryArchive, at url: URL) async throws {
        try await JSONSnipArchiveTransfer.write(
            archive,
            to: url,
            preparingAttachment: { attachment in
                do {
                    let prepared = try await self.attachmentPreparation.prepare(
                        [attachment],
                        for: .export,
                        fallbackURLs: archive.attachmentURLs
                    )
                    guard let readyURL = prepared[attachment.id] else {
                        throw SnipLibraryError.attachmentCopyFailed
                    }
                    return readyURL
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ArchiveAttachmentPreparationError(underlying: error)
                }
            }
        )
    }

    private func reloadUnlocked() async {
        if let checked = try? await session.checkedSnapshot(sortedBy: sortMode) {
            apply(checked)
        }
        recoverySnapshot = await session.refreshRecovery()
    }

    var needsAttentionCount: Int {
        recoverySnapshot.needsAttentionCount + legacyDraftCount
    }
    var unattributedLegacyDrafts: [(id: UUID, text: String)] {
        composerDrafts.unattributedLegacyDrafts()
    }

    func moveUnattributedLegacyDraftToInbox(_ id: UUID) {
        composerDrafts.moveUnattributedLegacyDraftToInbox(id)
        legacyDraftCount = composerDrafts.unattributedLegacyDrafts().count
        composerRedirection.inboxChanged()
    }
    var pendingRecoveredSnips: [RecoveredSnip] { recoverySnapshot.pendingSnips }
    var pendingRecoveredLists: [RecoveredListEdit] { recoverySnapshot.pendingLists }

    @discardableResult
    func resolveRecovery(_ id: UUID, choice: SnipRecoveryChoice) async -> Bool {
        await withCommandLock {
            guard editingID == nil else { return false }
            do {
                return try await resolveSavedSnipsRecovery(id, choice: choice)
            } catch {
                presentError(error, operation: "recovery.resolve")
                await reloadUnlocked()
                return false
            }
        }
    }

    func apply(_ state: SavedSnipsSessionState) {
        apply(state.library, reconcileOrphanDrafts: false)
        recoverySnapshot = state.recovery
    }

    func apply(_ snapshot: SnipLibrarySnapshot, reconcileOrphanDrafts: Bool = true) {
        snips = snapshot.snips
        lists = snapshot.lists
        let liveIDs = Set(lists.map(\.id))
        composerRedirection.listsReturned(liveIDs)
        if reconcileOrphanDrafts {
            for id in composerDrafts.draftListIDs()
                where !liveIDs.contains(id) && !composerRedirection.isRetired(id) {
                redirectDeletedListDraft(from: id)
            }
        }
        attachmentPreparation.replaceCachedURLs(with: snapshot.attachmentURLs)
        if let editingID, !snips.contains(where: { $0.id == editingID }) {
            closeInlineEditor()
        }
        reconcileActiveList()
        reconcileSelection()
        publishShareDestinations?(lists)
    }

    private func reconcileActiveList() {
        guard !displayedLists.contains(where: { $0.id == activeListID }) else { return }
        activeListID = SnipList.inboxID
        defaults.set(SnipList.inboxID.uuidString, forKey: Self.activeListDefaultsKey)
    }

    func setDoneLimit(_ limit: SnipDoneLimit) {
        guard editingID == nil else { return }
        doneLimit = limit
        limit.save(to: defaults)
        reconcileSelection()
    }

    func setSortMode(_ mode: SnipSortMode) {
        guard sortMode != mode else { return }
        sortMode = mode
        defaults.set(mode.rawValue, forKey: Self.sortModeDefaultsKey)
        snips = Snip.sorted(snips, by: mode)
        reconcileSelection()
    }

    func setAppearance(_ appearance: AppAppearance) {
        guard self.appearance != appearance else { return }
        self.appearance = appearance
        defaults.set(appearance.rawValue, forKey: Self.appearanceDefaultsKey)
    }

    @discardableResult
    func add(
        content: String,
        origin: SnipOrigin,
        source: SnipSource? = nil,
        attachmentURLs: [URL] = [],
        listID: UUID? = nil,
        requestID: UUID = UUID()
    ) async -> Bool {
        switch await addResult(
            content: content,
            origin: origin,
            source: source,
            attachmentURLs: attachmentURLs,
            listID: listID,
            requestID: requestID
        ) {
        case .success(.added):
            return true
        case .success(.duplicate):
            return false
        case .failure(let error):
            presentError(error, operation: "snip.add")
            return false
        }
    }

    func addResult(
        content: String,
        origin: SnipOrigin,
        source: SnipSource? = nil,
        attachmentURLs: [URL] = [],
        listID: UUID? = nil,
        requestID: UUID = UUID()
    ) async -> Result<SnipAddOutcome, Error> {
        await withCommandLock {
            await addResultUnlocked(
                content: content, origin: origin, source: source,
                attachmentURLs: attachmentURLs, listID: listID, requestID: requestID
            )
        }
    }

    private func addResultUnlocked(
        content: String,
        origin: SnipOrigin,
        source: SnipSource?,
        attachmentURLs: [URL],
        listID: UUID?,
        requestID: UUID
    ) async -> Result<SnipAddOutcome, Error> {
        let result = await performMutationUnlocked {
            let update = try await session.performLibraryCommand(
                .add(
                    content: content,
                    origin: origin,
                    source: source,
                    listID: listID ?? activeList.id,
                    attachmentURLs: attachmentURLs,
                    requestID: requestID,
                    now: Date()
                ),
                sortedBy: sortMode
            )
            return (update, update)
        }
        switch result {
        case .success(let update):
            clearFailure(for: "snip.add")
            guard case .add(let outcome) = update.outcome else {
                preconditionFailure("The library returned the wrong add outcome.")
            }
            switch outcome {
            case .added(let id):
                latestAddedSnipID = id
                return .success(.added(id))
            case .duplicate:
                return .success(.duplicate)
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    func update(
        id: UUID,
        content: String,
        attachmentURLs: [URL]? = nil,
        expectedUpdatedAt: Date? = nil
    ) async -> Bool {
        switch await updateResult(
            id: id,
            content: content,
            attachmentURLs: attachmentURLs,
            expectedUpdatedAt: expectedUpdatedAt
        ) {
        case .success:
            clearFailure(for: "snip.update")
            return true
        case .failure(let error):
            presentError(error, operation: "snip.update")
            return false
        }
    }

    func updateResult(
        id: UUID,
        content: String,
        attachmentURLs: [URL]? = nil,
        expectedUpdatedAt: Date? = nil
    ) async -> Result<Void, Error> {
        await performMutation {
            try await performUpdate(
                id: id, content: content,
                attachmentURLs: attachmentURLs, expectedUpdatedAt: expectedUpdatedAt
            )
        }
    }

    private func performUpdate(
        id: UUID,
        content: String,
        attachmentURLs: [URL]?,
        expectedUpdatedAt: Date?
    ) async throws -> (SnipLibraryUpdate, Void) {
        let update = try await session.performLibraryCommand(
            .update(
                id: id,
                content: content,
                attachmentURLs: attachmentURLs,
                expectedUpdatedAt: expectedUpdatedAt,
                now: Date()
            ),
            sortedBy: sortMode
        )
        return (update, ())
    }

    func selectList(_ list: SnipList, preservingSelection: Bool = false) {
        exitSearch()
        showListPage(list, preservingSelection: preservingSelection)
    }

    /// Changes the page without closing search, so a search selection moved
    /// to a new list stays on its results.
    private func showListPage(_ list: SnipList, preservingSelection: Bool) {
        guard editingID == nil else { return }
        activeListID = list.id
        defaults.set(list.id.uuidString, forKey: Self.activeListDefaultsKey)
        isShowingClipboard = false
        if !preservingSelection { selection = [] }
    }

    func showClipboard() {
        guard editingID == nil else { return }
        exitSearch()
        isShowingClipboard = true
        selection = []
    }

    func composerDraft(for listID: UUID) -> ComposerDraft {
        composerDrafts.draft(for: listID)
    }

    var composerDraftScope: String { composerDrafts.scope }

    var cliScopeToken: String {
        SnipCLIScopeToken.token(for: composerDrafts.scope)
    }

    func saveComposerText(_ text: String, for listID: UUID) {
        guard !composerRedirection.isRetired(listID) else { return }
        guard liveComposerListID(listID) != listID else {
            composerDrafts.setText(text, for: listID)
            if listID == SnipList.inboxID { composerRedirection.inboxChanged() }
            return
        }
        let inboxText = composerDrafts.draft(for: SnipList.inboxID).text
        if let updated = composerRedirection.redirect(text, from: listID, inboxText: inboxText) {
            composerDrafts.setText(updated, for: SnipList.inboxID)
        }
    }

    func flushComposerDrafts() {
        composerDrafts.flushText()
    }

    func addDraftAttachments(_ urls: [URL], to listID: UUID) {
        guard !composerRedirection.isRetired(listID) else { return }
        composerDrafts.add(urls, to: liveComposerListID(listID))
    }

    func replaceDraftAttachments(_ urls: [URL], in listID: UUID) {
        guard !composerRedirection.isRetired(listID) else { return }
        composerDrafts.replaceAttachments(urls, for: liveComposerListID(listID))
    }

    func addTemporaryDraftAttachment(_ url: URL, to listID: UUID) {
        guard !composerRedirection.isRetired(listID) else { return }
        composerDrafts.addTemporary(url, to: liveComposerListID(listID))
    }

    func stageScreenCapture() -> URL {
        composerDrafts.stageScreenCapture()
    }

    func finishScreenCapture(_ url: URL, in listID: UUID, succeeded: Bool) {
        guard !composerRedirection.isRetired(listID) else { return }
        composerDrafts.finishScreenCapture(
            url, in: liveComposerListID(listID), succeeded: succeeded
        )
    }

    func removeDraftAttachment(_ url: URL, from listID: UUID) {
        guard !composerRedirection.isRetired(listID) else { return }
        composerDrafts.remove(url, from: liveComposerListID(listID))
    }

    private func liveComposerListID(_ listID: UUID) -> UUID {
        lists.contains(where: { $0.id == listID }) ? listID : SnipList.inboxID
    }

    func clearDraft(for listID: UUID) {
        guard !composerRedirection.isRetired(listID) else { return }
        composerDrafts.clear(listID: listID)
        if listID == SnipList.inboxID { composerRedirection.inboxChanged() }
    }

    func moveComposerDraftToInbox(from listID: UUID) {
        composerDrafts.moveDraft(from: listID, to: SnipList.inboxID)
        composerDrafts.flushText()
        composerRedirection.inboxChanged()
    }

    private func redirectDeletedListDraft(from listID: UUID) {
        let text = composerDrafts.draft(for: listID).text
        composerDrafts.moveDraft(from: listID, to: SnipList.inboxID)
        composerDrafts.flushText()
        composerRedirection.listDeleted(listID, movedText: text)
    }

    func saveComposerDraft(
        content: String, listID: UUID, destinationListID: UUID? = nil,
        expectedScope: String? = nil, expectedLibraryRevision: UUID? = nil
    ) async -> Bool {
        let revision = expectedLibraryRevision ?? libraryRevision
        let scope = expectedScope ?? composerDrafts.scope
        let destinationID = destinationListID ?? listID
        return await withCommandLock {
            guard libraryRevision == revision, composerDrafts.scope == scope,
                  !composerRedirection.isRetired(listID),
                  liveComposerListID(listID) == listID,
                  lists.contains(where: { $0.id == destinationID }) else { return false }
            let snapshot = composerDrafts.beginSave(listID: listID, content: content)
            let result = await addResultUnlocked(
                content: snapshot.draft.text,
                origin: .quickEntry,
                source: nil,
                attachmentURLs: snapshot.draft.attachments,
                listID: destinationID,
                requestID: UUID()
            )
            let saved: Bool
            switch result {
            case .success(.added): saved = true
            case .success(.duplicate): saved = false
            case .failure(let error):
                presentError(error, operation: "snip.add")
                saved = false
            }
            composerDrafts.finishSave(snapshot, saved: saved)
            return saved
        }
    }

    func createList(
        name: String,
        systemImage: String,
        color: SnipListColorPreset? = nil,
        movingIDs: Set<UUID> = []
    ) async -> Bool {
        let result: Result<Void, Error>? = await withCommandLock {
            guard editingID == nil else { return nil }
            switch await runSavedSnipsCommand(
                .createList(name: name, systemImage: systemImage, color: color), route: .library
            ) {
            case .failure(let error):
                return .failure(error)
            case .success(.listCreated(let list)):
                let selectedMovingIDs = selection.intersection(movingIDs)
                showListPage(list, preservingSelection: !movingIDs.isEmpty)
                guard !movingIDs.isEmpty else { return .success(()) }
                let orderedIDs = snips.filter { movingIDs.contains($0.id) }.map(\.id)
                guard !orderedIDs.isEmpty else { return nil }
                let move: SnipLibraryCommand
                let nextSortMode: SnipSortMode?
                if sortMode == .manual {
                    move = .place(
                        ids: orderedIDs,
                        in: list.id,
                        before: nil,
                        basedOn: .manual
                    )
                    nextSortMode = .manual
                } else {
                    move = .moveChronologically(ids: orderedIDs, to: list.id)
                    nextSortMode = nil
                }
                let moveResult = await performCommandUnlocked(
                    command: move,
                    afterSelection: selectedMovingIDs,
                    afterSortMode: nextSortMode,
                    affectedIDs: Set(orderedIDs)
                )
                return moveResult?.map { _ in () }
            case .success:
                preconditionFailure("The library returned the wrong list outcome.")
            }
        }
        guard let result else { return false }
        if case .failure(let error) = result {
            presentError(error, operation: "list.create")
            return false
        }
        clearFailure(for: "list.create")
        return true
    }

    func deleteList(_ list: SnipList) async {
        guard list.id != SnipList.inboxID else { return }
        let result: Result<Void, Error>? = await withCommandLock {
            guard editingID == nil else { return nil }
            return await runSavedSnipsCommand(.deleteList(id: list.id), route: .library).map { _ in () }
        }
        if case .some(.failure(let error)) = result {
            presentError(error, operation: "list.delete")
        } else if case .some(.success) = result {
            clearDraft(for: list.id)
        }
    }

    func updateList(_ list: SnipList, name: String, systemImage: String, color: SnipListColorChange = .keep) async -> Bool {
        let result: Result<Void, Error>? = await withCommandLock {
            guard editingID == nil else { return nil }
            return await runSavedSnipsCommand(
                .updateList(id: list.id, name: name, systemImage: systemImage, color: color), route: .library
            ).map { _ in () }
        }
        guard let result else { return false }
        if case .failure(let error) = result {
            presentError(error, operation: "list.update")
            return false
        }
        clearFailure(for: "list.update")
        return true
    }

    func saveClipboardEntry(
        _ entry: ClipboardEntry,
        listID: UUID? = nil,
        before destinationID: UUID? = nil,
        placesManually: Bool = false
    ) async -> Bool {
        let entry = clipboardHistory.resolvedEntry(entry)
        let materialization: ClipboardSnipMaterialization
        do {
            materialization = try await Task.detached(priority: .utility) {
                try entry.materializeForSnip()
            }.value
        } catch {
            presentError(
                String(localized: "Couldn’t prepare the clipboard image. Try again."),
                operation: "attachment.prepare", diagnosticCode: diagnosticErrorCode(error)
            )
            return false
        }
        defer { materialization.removeTemporaryFiles() }
        let targetListID = listID ?? activeListID
        let result = await addResult(
            content: materialization.text,
            origin: .clipboard,
            source: materialization.source,
            attachmentURLs: materialization.fileURLs,
            listID: targetListID
        )
        switch result {
        case .success(.added(let id)):
            guard placesManually else { return true }
            return await move(ids: [id], to: targetListID, before: destinationID)
        case .success(.duplicate):
            return false
        case .failure(let error):
            presentError(error, operation: "snip.add")
            return false
        }
    }

    func deleteSelectionNow(ids targets: Set<UUID>? = nil) async {
        let ids = targets ?? selection
        guard !ids.isEmpty else { return }
        await withCommandLock {
            let deletableIDs = ids.subtracting(editingID.map { [$0] } ?? [])
            _ = await deleteSavedSnips(ids: deletableIDs)
        }
    }

    func performUndoAction(_ toast: AppToast) async {
        await withCommandLock { await restoreUndo(toast) }
    }

    func expireUnavailableUndoRetry(token: UUID, operation: StaticString) {
        guard snackbarAndErrors.retainsUndo(token) else { return }
        presentError(
            String(localized: "Undo is no longer available because the snips changed."),
            operation: operation, diagnosticCode: "undo.unavailable"
        )
    }

    func showSnackbar(_ snackbar: AppToast) {
        snackbarAndErrors.show(snackbar)
    }

    func showSnackbarUnlessActionable(_ snackbar: AppToast) {
        snackbarAndErrors.showUnlessActionable(snackbar)
    }

    var importPreviewSummary: String {
        pendingImportPreview?.value.localizedSummary ?? ""
    }

    func previewBackupImport(from url: URL) async {
        await withCommandLock {
            let operation = backupImport.beginPreview(keepingCurrentPreview: true)
            do {
                let preview = try await stageBackupImport(from: url)
                backupImport.present(preview, for: operation)
            } catch {
                backupImport.failPreview(operation)
                presentError(error)
            }
        }
    }

    func confirmBackupImport() async {
        guard let preview = backupImport.beginConfirmation(keepingPreviewVisible: true) else { return }
        await withCommandLock {
            guard editingID == nil else { return }
            do {
                let imported = try await applyBackupImport(preview.id, sortedBy: sortMode)
                presentImportedBackup(imported)
                scheduleCloudSync()
            } catch {
                backupImport.finishConfirmation()
                presentError(error)
                await reloadUnlocked()
            }
        }
    }

    var copiedButCouldNotMarkDone: String {
        String(localized: "Copied, but couldn’t mark Done. Try marking Done again.")
    }

    func toggleDoneNow(
        ids: Set<UUID>,
        to pasteboard: NSPasteboard = .general
    ) async {
        guard !ids.isEmpty else { return }
        let shouldMarkDone = snips.contains {
            ids.contains($0.id) && $0.id != editingID && !$0.isPinned && !$0.isDone
        }
        await setDoneNow(shouldMarkDone, ids: ids, to: pasteboard)
    }

    func setDone(_ done: Bool, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        Task { await setDoneNow(done, ids: ids) }
    }

    func setDoneNow(
        _ done: Bool,
        ids: Set<UUID>,
        to pasteboard: NSPasteboard = .general
    ) async {
        guard !ids.isEmpty else { return }
        let snipsToCheck = done ? snips.filter {
            ids.contains($0.id) && $0.id != editingID && !$0.isPinned && !$0.isDone
        } : []
        if snipsToCheck.isEmpty {
            await withCommandLock {
                await setDoneWithoutCopyUnlocked(done, ids: ids)
            }
        } else {
            let versions = copiedSnipVersions(snipsToCheck)
            _ = await copyBeforeCommandLock(snipsToCheck, to: pasteboard) {
                await setDoneWithoutCopyUnlocked(
                    done,
                    ids: ids,
                    versions: versions,
                    copyToast: .copied(count: snipsToCheck.count)
                )
            }
        }
    }

    @discardableResult
    private func setDoneWithoutCopyUnlocked(
        _ done: Bool,
        ids: Set<UUID>,
        versions: [UUID: Date]? = nil,
        copyToast: AppToast? = nil
    ) async -> Bool {
        let changing = completionCandidates(ids: ids, excluding: editingID, versions: versions)
            .filter { $0.isDone != done }
        return await changeCompletion(done, snips: changing, guardingChanges: true, copyToast: copyToast)
    }

    func toggleDone(id: UUID) {
        Task { await toggleDoneNow(id: id) }
    }

    func toggleDoneNow(
        id: UUID,
        to pasteboard: NSPasteboard = .general
    ) async {
        await toggleDoneNow(ids: [id], to: pasteboard)
    }

    func togglePinned(id: UUID) async {
        await withCommandLock {
            guard editingID != id else { return }
            await performPinCommand(.togglePinned(id: id))
        }
    }

    func setPinned(ids: Set<UUID>, pinned: Bool) async {
        await withCommandLock {
            let eligibleIDs = ids.subtracting(editingID.map { [$0] } ?? [])
            guard !eligibleIDs.isEmpty else { return }
            await performPinCommand(.setPinned(ids: eligibleIDs, pinned: pinned))
        }
    }

    func setDoneAfterExternalDrop(versions: [UUID: Date]) {
        Task { await setDoneAfterExternalDropNow(versions: versions) }
    }

    func setDoneAfterExternalDropNow(versions: [UUID: Date]) async {
        await withCommandLock {
            let changing = completionCandidates(excluding: editingID, versions: versions).filter { !$0.isDone }
            _ = await changeCompletion(true, snips: changing, guardingChanges: true, copyToast: nil)
        }
    }

    @discardableResult
    func moveToList(
        ids: [UUID],
        listID: UUID,
        selectionAfterMove: Set<UUID>? = nil
    ) async -> Bool {
        let command = moveToListCommand(ids: ids, to: listID, sortedBy: sortMode, in: snips)
        return await moveSnips(
            command, ids: ids, selectionAfterMove: selectionAfterMove,
            afterSortMode: sortMode == .manual ? .manual : nil
        )
    }

    @discardableResult
    func move(
        ids: [UUID],
        to listID: UUID,
        before destinationID: UUID?,
        selectionAfterMove: Set<UUID>? = nil
    ) async -> Bool {
        await moveSnips(
            .place(ids: ids, in: listID, before: destinationID, basedOn: sortMode),
            ids: ids, selectionAfterMove: selectionAfterMove, afterSortMode: .manual
        )
    }

    @discardableResult
    func moveChronologically(
        ids: [UUID],
        to listID: UUID,
        selectionAfterMove: Set<UUID>? = nil
    ) async -> Bool {
        await moveSnips(.moveChronologically(ids: ids, to: listID), ids: ids, selectionAfterMove: selectionAfterMove)
    }

    private func moveSnips(
        _ command: SnipLibraryCommand,
        ids: [UUID],
        selectionAfterMove: Set<UUID>?,
        afterSortMode: SnipSortMode? = nil
    ) async -> Bool {
        guard !ids.isEmpty, !ids.contains(where: { $0 == editingID }) else { return false }
        switch await performCommand(
            command: command,
            afterSelection: selectionAfterMove,
            afterSortMode: afterSortMode,
            affectedIDs: Set(ids)
        ) {
        case .success: return true
        case .failure(let error):
            presentError(error, operation: "snip.move")
            return false
        case nil: return false
        }
    }

    func moveSelectionNow(by offset: Int, ids targets: Set<UUID>? = nil) async {
        guard offset == -1 || offset == 1 else { return }
        let selectedIDs = targets ?? selection
        guard canReorder(ids: selectedIDs) else { return }
        let lists = Set(snips.filter { selectedIDs.contains($0.id) }.map(\.listID))
        guard let listID = lists.first else { return }
        let ids = snips.filter { $0.listID == listID && !$0.isPinned }.map(\.id)
        guard let firstSelectedIndex = ids.firstIndex(where: selectedIDs.contains) else { return }
        let movingIDs = ids.filter(selectedIDs.contains)
        let remainingIDs = ids.filter { !selectedIDs.contains($0) }
        let unselectedBefore = ids[..<firstSelectedIndex].filter { !selectedIDs.contains($0) }.count
        let insertionIndex = min(
            max(unselectedBefore + offset, 0),
            remainingIDs.count
        )
        guard insertionIndex != unselectedBefore else { return }
        let destinationID = insertionIndex < remainingIDs.count ? remainingIDs[insertionIndex] : nil
        _ = await move(ids: movingIDs, to: listID, before: destinationID)
    }

    func selectAllVisible() {
        guard canSelectVisibleSnips else { return }
        let ids = filteredSnips.map(\.id)
        applySelection(.init(selection: Set(ids), anchor: ids.first, focus: ids.last))
    }

    private var inlineEditOpeningView: (
        isShowingClipboard: Bool, isSearchExpanded: Bool, query: String, activeListID: UUID
    ) {
        (isShowingClipboard, isSearchExpanded, query, activeListID)
    }

    private var canOpenInlineEdit: Bool {
        (!isSearchExpanded || hasActiveQuery) && (!isShowingClipboard || isSearchExpanded)
    }

    @discardableResult
    func beginEditing(_ id: UUID) async -> Bool {
        guard !isCLIInteractionReserved else { return false }
        if editingID == id { return true }
        guard editingID == nil,
              canOpenInlineEdit,
              let snip = filteredSnips.first(where: { $0.id == id }) else { return false }
        let request = UUID()
        pendingEditOpening = (snipID: id, request: request)
        let startingView = inlineEditOpeningView
        do {
            _ = try await prepareAttachments(snip.attachments, for: .open)
            return await withCommandLock {
                if editingID == id { return true }
                guard pendingEditOpening?.snipID == id,
                      !isCLIInteractionReserved, editingID == nil,
                      inlineEditOpeningView == startingView,
                      let current = filteredSnips.first(where: { $0.id == id }),
                      current.attachments == snip.attachments else {
                    endEditOpening(request)
                    return false
                }
                openInlineEdit(current)
                return true
            }
        } catch is CancellationError {
            endEditOpening(request)
            return false
        } catch {
            let isLatest = pendingEditOpening?.request == request
            endEditOpening(request)
            if isLatest { presentError(error, operation: "attachment.prepare") }
            return false
        }
    }

    private func endEditOpening(_ request: UUID) {
        guard pendingEditOpening?.request == request else { return }
        pendingEditOpening = nil
    }

    @discardableResult
    func copySelection() -> Bool {
        copySnipsAndMarkDone(selectedSnips)
    }

    @discardableResult
    func copySnipsAndMarkDone(_ snips: [Snip]) -> Bool {
        guard !snips.isEmpty else { return false }
        Task { await copySnipsAndMarkDoneNow(snips) }
        return true
    }

    @discardableResult
    func copySnipsAndMarkDoneNow(
        _ snips: [Snip],
        to pasteboard: NSPasteboard = .general
    ) async -> Bool {
        let current = currentSnips(for: snips)
        let versions = copiedSnipVersions(current)
        return await copyBeforeCommandLock(
            current,
            to: pasteboard,
            requiresMutation: !versions.isEmpty
        ) {
            await setDoneWithoutCopyUnlocked(
                true,
                ids: Set(versions.keys),
                versions: versions,
                copyToast: .copied(count: current.count)
            )
        }
    }

    private func currentSnips(for requested: [Snip]) -> [Snip] {
        let currentByID = Dictionary(uniqueKeysWithValues: snips.map { ($0.id, $0) })
        return requested.compactMap { currentByID[$0.id] }
    }

    private func copiedSnipVersions(_ snips: [Snip]) -> [UUID: Date] {
        Dictionary(uniqueKeysWithValues: snips.lazy.filter {
            !$0.isPinned && !$0.isDone
        }.map { ($0.id, $0.updatedAt) })
    }

    private func copyBeforeCommandLock(
        _ snips: [Snip],
        to pasteboard: NSPasteboard,
        requiresMutation: Bool = true,
        mutation: @MainActor @Sendable () async -> Bool
    ) async -> Bool {
        guard !snips.isEmpty else { return false }
        let (token, task) = startClipboardWrite(snips, feedback: .silent, to: pasteboard)
        let copied = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard copied else { return false }
        guard requiresMutation else {
            if clipboardWrites.isCurrent(token) { snackbarAndErrors.showUnlessActionable(.copied(count: snips.count)) }
            return true
        }
        return await withCommandLock {
            guard clipboardWrites.isCurrent(token) else { return true }
            let failureID = latestFailure?.id
            let markedDone = await mutation()
            if latestFailure?.id == failureID { snackbarAndErrors.showUnlessActionable(.copied(count: snips.count)) }
            return markedDone
        }
    }

    @discardableResult
    func placeOnClipboard(
        _ placement: ClipboardPlacement,
        feedback: ClipboardPlacementFeedback = .notify,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        switch placement {
        case .snips(let snips):
            guard !snips.isEmpty else { return false }
            _ = startClipboardWrite(
                snips,
                feedback: feedback,
                to: pasteboard
            )
            return true
        case .clipboardEntry(let entry):
            clipboardWrites.supersede()
            return placeClipboardEntry(entry, feedback: feedback)
        }
    }

    @discardableResult
    func placeOnClipboardNow(
        _ placement: ClipboardPlacement,
        feedback: ClipboardPlacementFeedback = .notify,
        to pasteboard: NSPasteboard = .general
    ) async -> Bool {
        switch placement {
        case .snips(let snips):
            guard !snips.isEmpty else { return false }
            let task = startClipboardWrite(
                snips,
                feedback: feedback,
                to: pasteboard
            ).task
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        case .clipboardEntry(let entry):
            clipboardWrites.supersede()
            return placeClipboardEntry(entry, feedback: feedback)
        }
    }

    @discardableResult
    func placeClipboardEntry(
        _ entry: ClipboardEntry,
        feedback: ClipboardPlacementFeedback = .notify
    ) -> Bool {
        let failureID = latestFailure?.id
        guard clipboardHistory.restore(entry) else {
            presentError(
                String(localized: "Couldn’t set the clipboard. Try again."),
                operation: "clipboard.write", diagnosticCode: "pasteboard.writeFailed"
            )
            return false
        }
        dismissCopyFailure(matching: failureID)
        if feedback == .notify {
            clipboardCopyPulse = ClipboardCopyPulse(entryID: entry.id)
        }
        return true
    }

    private func startClipboardWrite(
        _ snips: [Snip],
        feedback: ClipboardPlacementFeedback,
        to pasteboard: NSPasteboard
    ) -> (token: ClipboardWriteSequence.Token, task: Task<Bool, Never>) {
        let changeCount = pasteboard.changeCount
        return clipboardWrites.begin { token in
            let write = SnipClipboardWrite(
                token: token,
                pasteboard: pasteboard,
                expectedChangeCount: changeCount
            )
            let failureID = latestFailure?.id
            return Task {
                defer { clipboardWrites.finish(token) }
                let copied = await placeSnipsOnClipboard(snips, with: write)
                guard copied, !Task.isCancelled, clipboardWrites.isCurrent(token) else { return copied }
                dismissCopyFailure(matching: failureID)
                if feedback == .notify { snackbarAndErrors.showUnlessActionable(.copied(count: snips.count)) }
                return copied
            }
        }
    }

    private func placeSnipsOnClipboard(
        _ snips: [Snip],
        with write: SnipClipboardWrite
    ) async -> Bool {
        let pasteboard = write.pasteboard
        guard !snips.isEmpty else { return false }
        let attachments = attachmentPreparation.unique(snips.flatMap(\.attachments))
        let prepared: [UUID: URL]
        do {
            prepared = try await prepareAttachments(attachments, for: .copy)
        } catch is CancellationError {
            return false
        } catch {
            if shouldPresentClipboardError(for: write) {
                presentError(error, operation: "attachment.prepare")
            }
            return false
        }
        let export: SnipPasteboardExport
        do {
            let text = SnipFormatter.formatForClipboard(snips: snips)
            guard clipboardWrites.isCurrent(write.token),
                  write.leavesPasteboardUnchanged else { return false }
            export = try await preparePasteboardExport(
                text,
                attachments.compactMap { prepared[$0.id] }
            )
        } catch is CancellationError {
            return false
        } catch {
            if shouldPresentClipboardError(for: write) {
                presentError(error, operation: "clipboard.export")
            }
            return false
        }
        guard !Task.isCancelled,
              clipboardWrites.isCurrent(write.token),
              write.leavesPasteboardUnchanged else { return false }
        let objects = export.pasteboardWriters()
        let writeChangeCount = pasteboard.clearContents()
        let copied = pasteboard.writeObjects(objects)
        if copied {
            export.retainStagedResources(
                untilPasteboardChanges: pasteboard,
                from: writeChangeCount
            )
            clipboardHistory.captureNow(from: pasteboard)
        } else {
            presentError(
                String(localized: "Couldn’t copy that content. Try again."),
                operation: "clipboard.write", diagnosticCode: "pasteboard.writeFailed"
            )
        }
        return copied
    }

    private func shouldPresentClipboardError(for write: SnipClipboardWrite) -> Bool {
        !Task.isCancelled
            && clipboardWrites.isCurrent(write.token)
            && write.leavesPasteboardUnchanged
    }

    func waitForPendingClipboardWrite() async {
        _ = await clipboardWrites.pendingTask?.value
    }

    func clearDownloadedFiles() async throws {
        try await attachmentPreparation.clearDownloadedFiles()
        await reload()
    }

    func mergeSelectionNow(ids targets: Set<UUID>? = nil) async {
        let ids = targets ?? selection
        let snipsToMerge = snips.filter { ids.contains($0.id) }
        guard ids.count >= 2, snipsToMerge.count >= 2 else { return }
        let result = await performCommand(
            command: .merge(ids: ids, now: Date()),
            affectedIDs: ids
        )
        guard let result else { return }
        switch result {
        case .success(.merged):
            break
        case .success:
            preconditionFailure("The library returned the wrong merge outcome.")
        case .failure(let error):
            presentError(error, operation: "snip.merge")
        }
    }

    private func performMutation<Value: Sendable>(
        _ mutation: () async throws -> (SnipLibraryUpdate, Value)
    ) async -> Result<Value, Error> {
        await withCommandLock {
            await performMutationUnlocked(mutation)
        }
    }

    func performMutationUnlocked<Value: Sendable>(
        didMutate: @MainActor @Sendable (Value) -> Bool = { _ in true },
        _ mutation: () async throws -> (SnipLibraryUpdate, Value)
    ) async -> Result<Value, Error> {
        do {
            let undoToken = snackbarAndErrors.undoToken
            let (update, value) = try await mutation()
            let changed = didMutate(value)
            if changed { await clearUndoUnlessRetained(undoToken) }
            apply(update.snapshot)
            if changed { scheduleCloudSync() }
            return .success(value)
        } catch {
            return .failure(error)
        }
    }

    func clearUndoUnlessRetained(_ token: UUID?) async {
        if let token, await session.retainsUndo(token: token) { return }
        clearPendingUndoToast()
    }

    private func performPinCommand(_ command: SnipLibraryCommand) async {
        switch await runSavedSnipsCommand(command, route: .library) {
        case .failure(let error): presentError(error, operation: "snip.pin")
        case .success: clearFailure(for: "snip.pin")
        }
    }

    private func performCommand(
        command: SnipLibraryCommand,
        afterSelection: Set<UUID>? = nil,
        afterSortMode: SnipSortMode? = nil,
        affectedIDs: Set<UUID>
    ) async -> Result<SnipLibraryOutcome, Error>? {
        await withCommandLock {
            await performCommandUnlocked(
                command: command,
                afterSelection: afterSelection,
                afterSortMode: afterSortMode,
                affectedIDs: affectedIDs
            )
        }
    }

    private func performCommandUnlocked(
        command: SnipLibraryCommand,
        afterSelection: Set<UUID>? = nil,
        afterSortMode: SnipSortMode? = nil,
        affectedIDs: Set<UUID>
    ) async -> Result<SnipLibraryOutcome, Error>? {
        if let editingID, affectedIDs.contains(editingID) { return nil }
        return await runSavedSnipsCommand(command) { _ in
            if let afterSortMode { setSortMode(afterSortMode) }
            if let afterSelection { selection = afterSelection }
        }
    }

    func withCommandLock<Value: Sendable>(
        _ operation: @MainActor @Sendable () async -> Value
    ) async -> Value {
        await session.withExclusiveAccess { _ in await operation() }
    }

    func scheduleCloudSync() {
        guard let cloudSyncHandler else { return }
        Task { await cloudSyncHandler.scheduleSyncAfterLocalChange() }
    }
}
