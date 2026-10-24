import AppKit
import CryptoKit
import SnipSnapCore

/// Sparkle stays in app assembly; command handling only needs these updater effects.
@MainActor
struct SnipCLIApplicationUpdates {
    let settings: UpdateChannelSettings
    var settingsVisible = false
    var canCheckForUpdates: @MainActor () -> Bool = { false }
    var checkForUpdates: @MainActor () -> Void = {}
    var resetUpdateCycle: @MainActor () -> Void = {}
}

/// Routes application commands through the existing UI, settings, and cloud services.
@MainActor
final class SnipCLIApplicationHandler {
    private let model: AppModel
    private let coordinator: AppCoordinator
    private let syncedContentSettings: SyncedContentSettingsModel
    private let updates: SnipCLIApplicationUpdates
    private let cloudSyncHandler: (any OptionalCloudSyncHandling)?
    private let accountNoticeModel: AppleAccountNoticeModel?
    private let panel: @MainActor () -> NSWindow?

    init(
        model: AppModel,
        coordinator: AppCoordinator,
        syncedContentSettings: SyncedContentSettingsModel,
        updates: SnipCLIApplicationUpdates,
        cloudSyncHandler: (any OptionalCloudSyncHandling)?,
        accountNoticeModel: AppleAccountNoticeModel?,
        panel: @escaping @MainActor () -> NSWindow?
    ) {
        self.model = model
        self.coordinator = coordinator
        self.syncedContentSettings = syncedContentSettings
        self.updates = updates
        self.cloudSyncHandler = cloudSyncHandler
        self.accountNoticeModel = accountNoticeModel
        self.panel = panel
    }

    func handle(
        _ request: SnipCLIRequest, action: SnipCLIApplicationAction
    ) async throws -> SnipCLIReceipt {
        try validateCLIApplicationScope(request)
        @MainActor
        func receipt(_ result: SnipCLIApplicationResult, message: String? = nil,
                     failed: Bool = false, snips: [Snip] = []) -> SnipCLIReceipt {
            SnipCLIReceipt(request: request, status: failed ? .failed : .success,
                snips: snips, message: message,
                extendedResult: .application(result))
        }
        switch action {
        case .settingsShow:
            return receipt(cliSettingsResult())
        case .setSetting(let key, let value, let revision):
            return try await cliApplicationLocked(request) {
                try self.requireCLIRevision(revision, current: self.cliSettingsResult())
                try self.requireCLISettingsAvailable()
                try SnipCLIApplicationSettings.apply(key, value: value, model: self.model,
                    updates: self.updates.settings, updatesAvailable: self.updates.settingsVisible) {
                        self.updates.resetUpdateCycle()
                }
                return receipt(self.cliSettingsResult(), message: "Updated settings.")
            }
        case .setShortcut(let target, let binding, let revision):
            return try await cliApplicationLocked(request) {
                try self.requireCLIRevision(revision, current: self.cliSettingsResult())
                try self.requireCLISettingsAvailable()
                try self.cliSetShortcut(target, binding: binding)
                return receipt(self.cliSettingsResult(), message: "Updated shortcut.")
            }
        case .resetShortcut(let target, let revision):
            return try await cliApplicationLocked(request) {
                try self.requireCLIRevision(revision, current: self.cliSettingsResult())
                try self.requireCLISettingsAvailable()
                if let global = self.cliGlobalShortcut(target) {
                    try self.coordinator.setShortcut(global.defaultTrigger, for: global)
                } else {
                    try self.coordinator.resetShortcut(target == .merge ? .merge : .toggleDone)
                }
                return receipt(self.cliSettingsResult(), message: "Reset shortcut.")
            }
        case .syncStatus: return receipt(cliSyncResult())
        case .setSync(let enabled, let currentCache, let revision):
            try requireCLIRevision(revision, current: cliSyncResult())
            try model.beginCLIScopeChange()
            defer { model.endCLIScopeChange() }
            if enabled {
                if syncedContentSettings.mode != .iCloudSync {
                    guard syncedContentSettings.canEnable else { throw cliApplicationError(syncedContentSettings.detail) }
                    await syncedContentSettings.enableICloudSync()
                }
            } else if syncedContentSettings.mode != .localOnly {
                guard syncedContentSettings.canDisable else { throw cliApplicationError(syncedContentSettings.detail) }
                model.clipboardHistory.stopSync()
                await syncedContentSettings.disableICloudSync(currentCache ? .useCurrentCache : .refreshThenCopy)
            } else if syncedContentSettings.canCancelEnable {
                throw cliApplicationError("iCloud setup is still pending. Use sync cancel-setup with the current revision.")
            }
            // Mode transitions reload the model through the existing completion hooks.
            return SnipCLIReceipt(request: request, status: cliSyncHasFailure ? .failed : .success,
                message: syncedContentSettings.detail, extendedResult: .application(cliSyncResult()),
                resultingScopeToken: model.cliScopeToken)
        case .cancelSyncSetup(let revision):
            try requireCLIRevision(revision, current: cliSyncResult())
            try model.beginCLIScopeChange()
            defer { model.endCLIScopeChange() }
            guard syncedContentSettings.canCancelEnable else {
                throw cliApplicationError("There is no cancellable iCloud setup.")
            }
            await syncedContentSettings.cancelICloudSyncSetup()
            return SnipCLIReceipt(request: request, status: cliSyncHasFailure ? .failed : .success,
                message: syncedContentSettings.detail, extendedResult: .application(cliSyncResult()),
                resultingScopeToken: model.cliScopeToken)
        case .retrySync:
            try model.beginCLIScopeChange()
            defer { model.endCLIScopeChange() }
            if syncedContentSettings.mode == .localOnly {
                guard syncedContentSettings.canEnable else { throw cliApplicationError(syncedContentSettings.detail) }
                await syncedContentSettings.enableICloudSync()
            } else {
                guard syncedContentSettings.canSyncNow, let cloudSyncHandler else {
                    throw cliApplicationError("iCloud sync is busy or unavailable. Check sync status.")
                }
                await cloudSyncHandler.retrySyncWhenPossible()
            }
            return SnipCLIReceipt(request: request, status: cliSyncHasFailure ? .failed : .success,
                message: syncedContentSettings.detail, extendedResult: .application(cliSyncResult()),
                resultingScopeToken: model.cliScopeToken)
        case .clipboardSyncStatus: return receipt(cliClipboardSyncResult())
        case .setClipboardSync(let enabled, let revision):
            return try await cliApplicationLocked(request) {
                try self.requireCLIRevision(revision, current: self.cliClipboardSyncResult())
                guard !enabled || self.syncedContentSettings.canEnableClipboardSync else {
                    throw self.cliApplicationError("Enable iCloud sync and finish setup before enabling clipboard sync.")
                }
                self.model.clipboardHistory.setSyncEnabled(enabled)
                return receipt(self.cliClipboardSyncResult(), message: "Updated clipboard sync.")
            }
        case .retryClipboardSync:
            guard model.clipboardHistory.syncIsActive, !model.clipboardHistory.isSyncing else {
                throw cliApplicationError("Clipboard sync is off or already running. Check sync clipboard status.")
            }
            await model.clipboardHistory.syncNow()
            return receipt(cliClipboardSyncResult(), message: model.clipboardHistory.syncError,
                           failed: model.clipboardHistory.syncError != nil)
        case .resolveAccount(let choice, let revision, let confirmed):
            try requireCLIRevision(revision, current: cliSyncResult())
            guard choice != .remove || confirmed else { throw cliApplicationError("Removal requires --yes.") }
            guard let accountNoticeModel, accountNoticeModel.showsResolutionActions,
                  !accountNoticeModel.isResolving else {
                throw cliApplicationError("There is no account notice to resolve.")
            }
            try model.beginCLIScopeChange()
            defer { model.endCLIScopeChange() }
            await accountNoticeModel.resolve(choice == .keep ? .keepLocalCopy : .remove)
            return SnipCLIReceipt(request: request,
                status: accountNoticeModel.errorMessage != nil ? .failed : .success,
                message: accountNoticeModel.errorMessage, extendedResult: .application(cliSyncResult()),
                resultingScopeToken: model.cliScopeToken)
        case .diagnosticsStatus:
            return receipt(try cliDiagnosticsResult())
        case .exportDiagnostics(let path):
            guard !path.isEmpty else { throw cliApplicationError("Choose a diagnostic export path.") }
            let data = try Data(contentsOf: AppDiagnosticsExport.makeShareableFile())
            let destination = URL(fileURLWithPath: path)
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() } }
            // An export never overwrites an existing file.
            try data.write(to: destination, options: .withoutOverwriting)
            return receipt(SnipCLIApplicationResult(values: ["bytes": String(data.count)]),
                           message: "Exported diagnostics.")
        case .clearDiagnostics(let revision, let confirmed):
            guard confirmed else { throw cliApplicationError("Clearing diagnostics requires --yes.") }
            guard try AppDiagnosticsExport.clear(ifRevision: revision) else {
                throw cliApplicationError("The state changed. Read its status again and use the latest revision with a new request ID.")
            }
            return receipt(try cliDiagnosticsResult(), message: "Cleared diagnostics.")
        case .attachmentCacheStatus:
            return receipt(try await cliAttachmentCacheResult(request))
        case .clearAttachmentCache(let revision, let confirmed):
            guard confirmed else { throw cliApplicationError("Clearing the attachment cache requires --yes.") }
            try validateCLIApplicationScope(request)
            guard let cloudSyncHandler else { throw cliApplicationError("The iCloud attachment cache is unavailable.") }
            let sourceScope = SnipRecoveryScope(model.composerDraftScope)
            guard try await cloudSyncHandler.clearDownloadedFiles(ifRevision: revision, in: sourceScope) else {
                throw cliApplicationError("The state changed. Read its status again and use the latest revision with a new request ID.")
            }
            return receipt(try await cliAttachmentCacheResult(request), message: "Cleared downloaded attachments.")
        case .status:
            return receipt(cliApplicationStatus())
        case .show:
            try cliShowPanel()
            return receipt(cliApplicationStatus(), message: "Showing Snip Snap.")
        case .hide:
            try requireCLIInteractionAvailable()
            coordinator.hidePanel(restoringPreviousApplication: false)
            return receipt(cliApplicationStatus(), message: "Hid Snip Snap.")
        case .showClipboard:
            try requireCLIInteractionAvailable()
            return try await cliApplicationLocked(request) {
                guard self.model.editingID == nil else { throw SnipCLIRequestError.editingInProgress }
                try self.cliShowPanel()
                self.model.showClipboard()
                self.model.exitSearch()
                return receipt(self.cliApplicationStatus(), message: "Showing clipboard history.")
            }
        case .closeSearch:
            try requireCLIInteractionAvailable()
            return try await cliApplicationLocked(request) {
                guard self.model.editingID == nil else { throw SnipCLIRequestError.editingInProgress }
                self.model.exitSearch()
                return receipt(self.cliApplicationStatus(), message: "Closed search.")
            }
        case .selectList(let selector):
            try requireCLIInteractionAvailable()
            return try await cliApplicationLocked(request) {
                guard self.model.editingID == nil else { throw SnipCLIRequestError.editingInProgress }
                let snapshot = try await self.model.session.checkedSnapshot(sortedBy: self.model.sortMode)
                try self.validateCLIApplicationScope(request)
                guard self.model.editingID == nil, !self.model.cliDialogIsPresented() else {
                    throw SnipCLIRequestError.editingInProgress
                }
                let list = try self.model.cliList(selector, in: snapshot.lists)
                try self.cliShowPanel()
                self.model.exitSearch()
                self.model.selectList(list)
                return receipt(self.cliApplicationStatus(), message: "Selected list.")
            }
        case .search(let query):
            try requireCLIInteractionAvailable()
            model.enterSearch()
            model.query = query
            coordinator.focusPanelSearch()
            return receipt(cliApplicationStatus(), message: "Opened search.")
        case .openSettings:
            try requireCLIDialogAvailable()
            if coordinator.openSettingsAction == nil { try cliShowPanel() }
            for _ in 0..<50 where coordinator.openSettingsAction == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            try validateCLIApplicationScope(request)
            try requireCLIDialogAvailable()
            guard let openSettings = coordinator.openSettingsAction else {
                throw cliApplicationError("Settings is still opening. Try again.")
            }
            openSettings()
            NSApp.activate()
            return receipt(cliApplicationStatus(), message: "Opened Settings.")
        case .captureSelection:
            let snip = try await coordinator.captureSelectionForCLI(
                requestID: request.requestID, scopeToken: request.scopeToken)
            return receipt(cliApplicationStatus(), message: "Captured selection \(snip.id.uuidString).", snips: [snip])
        case .captureScreen:
            let snip = try await cliCaptureScreen(request)
            return receipt(cliApplicationStatus(), message: "Captured screen area \(snip.id.uuidString).", snips: [snip])
        case .checkForUpdates:
            guard updates.canCheckForUpdates() else {
                throw cliApplicationError("Update checks are unavailable or already running.")
            }
            updates.checkForUpdates()
            return receipt(SnipCLIApplicationResult(values: ["update-check": "started"]),
                           message: "Started checking for updates. Follow the app’s update window.")
        }
    }

    private func validateCLIApplicationScope(_ request: SnipCLIRequest) throws {
        guard request.scopeToken != nil, request.scopeToken == model.cliScopeToken else {
            throw SnipCLIRequestError.scopeChanged
        }
    }

    private func cliApplicationLocked<T: Sendable>(
        _ request: SnipCLIRequest, _ operation: @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        let result: Result<T, Error> = await model.withCommandLock {
            do {
                try self.validateCLIApplicationScope(request)
                try self.model.beginCLIMutation()
                defer { self.model.endCLIMutation() }
                return .success(try await operation())
            } catch { return .failure(error) }
        }
        return try result.get()
    }

    private func cliApplicationError(_ message: String) -> NSError {
        NSError(domain: "SnipSnap.CLI.Application", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func requireCLISettingsAvailable() throws {
        guard model.editingID == nil else { throw SnipCLIRequestError.editingInProgress }
        guard !coordinator.panelDialogs.isPresented else { throw cliApplicationError("Close the current dialog before changing settings.") }
        guard !ShortcutRecordingState.isActive else { throw cliApplicationError("Finish recording the current shortcut first.") }
    }

    private func requireCLIInteractionAvailable() throws {
        try requireCLIDialogAvailable()
        guard model.editingID == nil, !model.cliDialogIsPresented() else {
            throw SnipCLIRequestError.editingInProgress
        }
    }

    private func requireCLIDialogAvailable() throws {
        guard !model.isCLIInteractionReserved else { throw SnipLibraryError.modeTransitionInProgress }
        guard !model.cliDialogIsPresented() else { throw SnipCLIRequestError.editingInProgress }
    }

    private func requireCLIRevision(_ revision: String, current: SnipCLIApplicationResult) throws {
        guard revision == current.revision else {
            throw cliApplicationError("The state changed. Read its status again and use the latest revision with a new request ID.")
        }
    }

    private func cliSettingsResult() -> SnipCLIApplicationResult {
        var values = [
            "appearance": model.appearance.rawValue,
            "sort": model.sortMode.rawValue,
            "completion-filter": model.completionFilter.rawValue,
            "clipboard-only-pinned": model.clipboardViewOptions.onlyPinned ? "on" : "off",
            "clipboard-newest-first": model.clipboardViewOptions.newestFirst ? "on" : "off",
            "beta-updates": updates.settings.includesBetaUpdates ? "on" : "off",
            "updates-available": String(updates.settingsVisible),
        ]
        for target in SnipCLIShortcutAction.allCases {
            if let global = cliGlobalShortcut(target) {
                values["shortcut.\(target.rawValue)"] = cliShortcutDescription(coordinator.shortcutSettings.configuration.trigger(for: global))
            } else {
                values["shortcut.\(target.rawValue)"] = cliChordDescription(coordinator.shortcutSettings.chord(for: target == .merge ? .merge : .toggleDone))
            }
        }
        return SnipCLIApplicationResult(values: values)
    }

    private func cliSyncResult() -> SnipCLIApplicationResult {
        let state: String
        switch syncedContentSettings.state {
        case .ready: state = "ready"
        case .enabling(let issue): state = "enabling" + (issue.map { ":" + $0.diagnosticCode } ?? "")
        case .syncing: state = "syncing"
        case .disabling: state = "disabling"
        case .deleting: state = "deleting"
        case .removalPending: state = "removal-pending"
        case .deleted: state = "deleted"
        case .failed(let issue): state = "failed:" + issue.diagnosticCode
        }
        let notice: String
        switch accountNoticeModel?.notice {
        case .paused: notice = "paused"
        case .signedOut: notice = "signed-out"
        case .accountChanged: notice = "account-changed"
        case nil: notice = "none"
        }
        return SnipCLIApplicationResult(values: [
            "mode": syncedContentSettings.mode == .iCloudSync ? "icloud-sync" : "local-only",
            "state": state, "status": syncedContentSettings.statusTitle,
            "detail": syncedContentSettings.detail, "account-notice": notice,
            "account-resolution-available": String(accountNoticeModel?.showsResolutionActions == true),
            "can-enable": String(syncedContentSettings.canEnable),
            "can-disable": String(syncedContentSettings.canDisable),
            "can-cancel-setup": String(syncedContentSettings.canCancelEnable),
        ])
    }

    private var cliSyncHasFailure: Bool {
        if case .failed = syncedContentSettings.state { return true }
        return false
    }

    private func cliClipboardSyncResult() -> SnipCLIApplicationResult {
        SnipCLIApplicationResult(values: [
            "enabled": String(model.clipboardHistory.clipboardSyncEnabled),
            "active": String(model.clipboardHistory.syncIsActive),
            "syncing": String(model.clipboardHistory.isSyncing),
            "error": model.clipboardHistory.syncError ?? "",
            "can-enable": String(syncedContentSettings.canEnableClipboardSync),
        ])
    }

    private func cliApplicationStatus() -> SnipCLIApplicationResult {
        SnipCLIApplicationResult(values: [
            "visible": String(panel()?.isVisible == true),
            "active-list-id": model.activeListID.uuidString,
            "view": model.isShowingClipboard ? "clipboard" : "snips",
            "search-expanded": String(model.isSearchExpanded),
            "editing": String(model.editingID != nil),
            "dialog-presented": String(coordinator.panelDialogs.isPresented),
            "accessibility-granted": String(coordinator.accessibilityPermissions.refresh()),
            "screen-recording-granted": String(CGPreflightScreenCaptureAccess()),
        ])
    }

    private func cliDiagnosticsResult() throws -> SnipCLIApplicationResult {
        let snapshot = try AppDiagnosticsExport.snapshot()
        return SnipCLIApplicationResult(values: [
            "bytes": String(snapshot.byteCount),
            "content-revision": snapshot.revision,
        ], revision: snapshot.revision)
    }

    private func cliAttachmentCacheResult(_ request: SnipCLIRequest) async throws -> SnipCLIApplicationResult {
        try validateCLIApplicationScope(request)
        let sourceScope = SnipRecoveryScope(model.composerDraftScope)
        let snapshot = try await cloudSyncHandler?.downloadedAttachmentCache(in: sourceScope)
        try validateCLIApplicationScope(request)
        var values = ["available": String(cloudSyncHandler != nil), "scope": model.cliScopeToken]
        for (id, state) in snapshot?.states ?? [:] {
            values["attachment.\(id.uuidString)"] = String(describing: state)
        }
        if let snapshot {
            return SnipCLIApplicationResult(values: values, revision: snapshot.revision)
        }
        return SnipCLIApplicationResult(values: values)
    }

    private func cliShowPanel() throws {
        guard let mainPanel = panel() else { throw cliApplicationError("Snip Snap is still opening. Try again.") }
        mainPanel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func cliGlobalShortcut(_ action: SnipCLIShortcutAction) -> GlobalHotKeyAction? {
        switch action {
        case .captureSelection: .captureSelection
        case .togglePanel: .togglePanel
        case .toggleClipboard: .toggleClipboard
        case .toggleDone, .merge: nil
        }
    }

    private func cliSetShortcut(_ action: SnipCLIShortcutAction, binding: SnipCLIShortcutBinding) throws {
        let trigger: ShortcutTrigger
        switch binding {
        case .doubleShift(let right): trigger = .doubleShift(right ? .right : .left)
        case .commandDoubleShift(let right): trigger = .commandDoubleShift(right ? .right : .left)
        case .chord(let key, let modifiers, let label):
            guard key <= 127, modifiers & ~UInt32(0x1B00) == 0, !label.isEmpty, label.count <= 32 else {
                throw cliApplicationError("Invalid keyboard shortcut.")
            }
            trigger = .keyChord(ShortcutKeyChord(keyCode: key, modifiers: modifiers, keyLabel: label))
        }
        if let global = cliGlobalShortcut(action) {
            if let chord = trigger.chord {
                guard chord.modifiers != 0, chord.supportsAppCommand else {
                    throw cliApplicationError("A global shortcut needs a valid key and modifier.")
                }
            }
            try coordinator.setShortcut(trigger, for: global)
        } else {
            guard let chord = trigger.chord else { throw cliApplicationError("App shortcuts require a key chord.") }
            try coordinator.setShortcut(chord, for: action == .merge ? .merge : .toggleDone)
        }
    }

    private func cliChordDescription(_ chord: ShortcutKeyChord) -> String {
        "chord \(chord.keyCode) \(chord.modifiers) \(chord.keyLabel)"
    }

    private func cliShortcutDescription(_ trigger: ShortcutTrigger) -> String {
        switch trigger {
        case .doubleShift(let side): "double-shift \(side == .right ? "right" : "left")"
        case .commandDoubleShift(let side): "command-double-shift \(side == .right ? "right" : "left")"
        case .keyChord(let chord): cliChordDescription(chord)
        }
    }

    private func cliCaptureScreen(_ request: SnipCLIRequest) async throws -> Snip {
        try requireCLIInteractionAvailable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("Screen Capture.png")
        coordinator.hidePanel(restoringPreviousApplication: false)
        guard try await InteractiveScreenCapture.capture(to: image) else {
            throw cliApplicationError("Screen capture was cancelled or macOS denied access. Check Privacy & Security > Screen Recording in System Settings.")
        }
        try Task.checkCancellation()
        // Capture can stay open while the user switches libraries. Admission checks the original scope.
        return try await model.performCLIMutation(scopeToken: request.scopeToken) {
            guard self.model.editingID == nil else { throw SnipCLIRequestError.editingInProgress }
            let update = try await self.model.session.performLibraryCommand(
                .add(content: "", origin: .selection, source: nil,
                     listID: self.model.activeListID, attachmentURLs: [image],
                     requestID: request.requestID, now: Date()), sortedBy: self.model.sortMode)
            guard let snip = update.snapshot.snips.first(where: { $0.requestID == request.requestID }) else {
                throw SnipCLIOutcomeUncertain()
            }
            return (update, snip)
        }
    }
}
