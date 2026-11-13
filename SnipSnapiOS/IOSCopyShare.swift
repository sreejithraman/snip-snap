import Foundation
import Observation
import SnipSnapCore
import SwiftUI
import UIKit

enum IOSCopyItem: Equatable {
    case text(String)
    case file(URL)
}

struct IOSCopySharePayload {
    let text: String
    let attachments: [URL]
    let unavailableFileNames: [String]

    var copyItems: [IOSCopyItem] {
        [.text(text)] + attachments.map(IOSCopyItem.file)
    }

    var textItems: [IOSCopyItem] {
        [.text(text)]
    }

    var attachmentItems: [IOSCopyItem] {
        attachments.map(IOSCopyItem.file)
    }
}

struct IOSCopySharePayloadBuilder {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func payload(
        for snips: [Snip],
        attachmentURL: (UUID) -> URL?
    ) -> IOSCopySharePayload {
        var attachments: [URL] = []
        var unavailableFileNames: [String] = []

        for attachment in uniqueAttachments(in: snips) {
            guard let url = attachmentURL(attachment.id), isAvailableFile(url) else {
                unavailableFileNames.append(attachment.fileName)
                continue
            }
            attachments.append(url)
        }

        return IOSCopySharePayload(
            text: SnipFormatter.formatForClipboard(snips: snips),
            attachments: attachments,
            unavailableFileNames: unavailableFileNames
        )
    }

    func uniqueAttachments(in snips: [Snip]) -> [SnipAttachment] {
        let orderedSnips = snips.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var seenAttachmentIDs: Set<UUID> = []
        return orderedSnips.flatMap(\.attachments).filter {
            seenAttachmentIDs.insert($0.id).inserted
        }
    }

    private func isAvailableFile(_ url: URL) -> Bool {
        guard fileManager.isReadableFile(atPath: url.path) else { return false }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

@MainActor
protocol IOSPasteboardWriting: AnyObject {
    func write(_ items: [IOSCopyItem]) -> Bool
}

@MainActor
final class IOSSystemPasteboard: NSObject, IOSPasteboardWriting {
    private let pasteboard: UIPasteboard
    private let stagingRoot: URL
    private let fileManager: FileManager
    private struct HeldLease {
        let lease: IOSPasteboardFileLease
        let changeCount: Int
    }

    private var heldLease: HeldLease?

    var activeLeaseDirectory: URL? {
        heldLease?.lease.directory
    }

    init(
        pasteboard: UIPasteboard = .general,
        stagingRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipSnapPasteboard", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.pasteboard = pasteboard
        self.stagingRoot = stagingRoot
        self.fileManager = fileManager
        super.init()
        restoreHeldLease()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pasteboardChanged),
            name: UIPasteboard.changedNotification,
            object: pasteboard
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pasteboardRemoved),
            name: UIPasteboard.removedNotification,
            object: nil
        )
    }

    func write(_ items: [IOSCopyItem]) -> Bool {
        let staged: (items: [IOSCopyItem], lease: IOSPasteboardFileLease?)
        do {
            staged = try stageFiles(in: items)
        } catch {
            return false
        }

        var providers: [NSItemProvider] = []
        for item in staged.items {
            switch item {
            case .text(let text):
                providers.append(NSItemProvider(object: text as NSString))
            case .file(let url):
                guard let provider = NSItemProvider(contentsOf: url) else {
                    staged.lease?.remove()
                    return false
                }
                provider.suggestedName = url.lastPathComponent
                providers.append(provider)
            }
        }
        pasteboard.setItemProviders(
            providers,
            localOnly: false,
            expirationDate: nil
        )
        releaseHeldLease()
        if let lease = staged.lease {
            let changeCount = pasteboard.changeCount
            hold(lease, changeCount: changeCount)
            lease.record(pasteboardName: pasteboard.name.rawValue, changeCount: changeCount)
        }
        removeStaleLeases(keeping: staged.lease?.directory)
        return true
    }

    @objc private func pasteboardChanged() {
        guard let heldLease, pasteboard.changeCount != heldLease.changeCount else { return }
        releaseHeldLease()
    }

    @objc private func pasteboardRemoved(_ notification: Notification) {
        let removedName = (notification.object as? UIPasteboard.Name)
            ?? (notification.object as? UIPasteboard)?.name
        guard removedName == pasteboard.name else { return }
        releaseHeldLease()
    }

    private func hold(_ lease: IOSPasteboardFileLease, changeCount: Int) {
        heldLease = HeldLease(lease: lease, changeCount: changeCount)
    }

    private func releaseHeldLease() {
        heldLease?.lease.remove()
        heldLease = nil
    }

    private func restoreHeldLease() {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil
        ) else { return }
        for directory in directories {
            guard let record = IOSPasteboardFileLease.record(in: directory) else {
                continue
            }
            guard record.pasteboardName == pasteboard.name.rawValue else { continue }
            if record.changeCount == pasteboard.changeCount, heldLease == nil {
                hold(
                    IOSPasteboardFileLease(directory: directory, fileManager: fileManager),
                    changeCount: record.changeCount
                )
            } else {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private func stageFiles(
        in items: [IOSCopyItem]
    ) throws -> (items: [IOSCopyItem], lease: IOSPasteboardFileLease?) {
        guard items.contains(where: { if case .file = $0 { true } else { false } }) else {
            return (items, nil)
        }
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let lease = IOSPasteboardFileLease(directory: directory, fileManager: fileManager)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var stagedItems: [IOSCopyItem] = []
            for (index, item) in items.enumerated() {
                switch item {
                case .text:
                    stagedItems.append(item)
                case .file(let sourceURL):
                    let itemDirectory = directory.appendingPathComponent(
                        String(index),
                        isDirectory: true
                    )
                    try fileManager.createDirectory(
                        at: itemDirectory,
                        withIntermediateDirectories: true
                    )
                    let stagedURL = itemDirectory.appendingPathComponent(
                        sourceURL.lastPathComponent,
                        isDirectory: false
                    )
                    try fileManager.copyItem(at: sourceURL, to: stagedURL)
                    stagedItems.append(.file(stagedURL))
                }
            }
            return (stagedItems, lease)
        } catch {
            lease.remove()
            throw error
        }
    }

    private func removeStaleLeases(keeping keptDirectory: URL?) {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil
        ) else { return }
        for directory in directories where directory != keptDirectory {
            try? fileManager.removeItem(at: directory)
        }
    }
}

@MainActor
private final class IOSPasteboardFileLease {
    struct Record: Codable {
        let pasteboardName: String
        let changeCount: Int
    }

    let directory: URL
    private let fileManager: FileManager

    private var recordURL: URL {
        directory.appendingPathComponent("lease.json", isDirectory: false)
    }

    init(directory: URL, fileManager: FileManager) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func remove() {
        try? fileManager.removeItem(at: directory)
    }

    func record(pasteboardName: String, changeCount: Int) {
        let record = Record(pasteboardName: pasteboardName, changeCount: changeCount)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: recordURL, options: .atomic)
    }

    static func record(in directory: URL) -> Record? {
        let url = directory.appendingPathComponent("lease.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
}

struct IOSUnavailableFilesNotice: Identifiable {
    let id = UUID()
    let payload: IOSCopySharePayload
    let versions: IOSCopiedSnipVersions

    var message: String {
        let names = payload.unavailableFileNames.joined(separator: ", ")
        return names.isEmpty
            ? String(localized: "Snip Snap couldn’t read one or more files.")
            : String(localized: "Snip Snap couldn’t read these files: \(names)")
    }
}

struct IOSShareRequest: Identifiable {
    let id: UUID
    let items: [IOSCopyItem]
    let completion: IOSShareCompletion?

    init(id: UUID = UUID(), items: [IOSCopyItem], completion: IOSShareCompletion? = nil) {
        self.id = id
        self.items = items
        self.completion = completion
    }
}

/// A terminal callback consumes its handler before resuming a suspended delivery.
@MainActor
final class IOSShareCompletion {
    private var handler: ((Result<AppDiagnosticSettingsModel.DeliveryOutcome, any Error>) -> Void)?

    init(_ handler: @escaping (Result<AppDiagnosticSettingsModel.DeliveryOutcome, any Error>) -> Void) {
        self.handler = handler
    }

    func finish(_ result: Result<AppDiagnosticSettingsModel.DeliveryOutcome, any Error>) {
        let pending = handler
        handler = nil
        pending?(result)
    }
}

/// Cancellation leaves native ownership intact until its callback or presenter teardown.
@MainActor
@Observable
final class IOSDiagnosticShareDelivery {
    var request: IOSShareRequest?

    func deliver(_ url: URL) async throws -> AppDiagnosticSettingsModel.DeliveryOutcome {
        try Task.checkCancellation()
        let id = UUID()
        defer { if request?.id == id { request = nil } }
        return try await withCheckedThrowingContinuation { continuation in
            request = IOSShareRequest(id: id, items: [.file(url)], completion: IOSShareCompletion {
                continuation.resume(with: $0)
            })
        }
    }
}

@MainActor
@Observable
final class IOSCopyShareCoordinator {
    private let pasteboard: any IOSPasteboardWriting
    private let payloadBuilder: IOSCopySharePayloadBuilder
    private let diagnostics: AppDiagnosticRecorder

    /// The latest copy request. A newer request makes every earlier one stale.
    private enum CopyRequest {
        case snips(token: UUID)
        case clipboardEntry(token: UUID, task: Task<Bool, Never>)

        var token: UUID {
            switch self {
            case .snips(let token), .clipboardEntry(let token, _): token
            }
        }
    }

    @ObservationIgnored private var copyRequest: CopyRequest?

    private(set) var unavailableFilesNotice: IOSUnavailableFilesNotice?
    private(set) var shareRequest: IOSShareRequest?

    /// The share sheet can only clear the request it was given.
    var shareSheetRequest: Binding<IOSShareRequest?> {
        Binding(
            get: { self.shareRequest },
            set: { if $0 == nil { self.shareRequest = nil } }
        )
    }

    init(
        pasteboard: any IOSPasteboardWriting = IOSSystemPasteboard(),
        payloadBuilder: IOSCopySharePayloadBuilder = IOSCopySharePayloadBuilder(),
        diagnostics: AppDiagnosticRecorder = AppDiagnosticRecorder.live
    ) {
        self.pasteboard = pasteboard
        self.payloadBuilder = payloadBuilder
        self.diagnostics = diagnostics
    }

    deinit {
        if case .clipboardEntry(_, let task) = copyRequest { task.cancel() }
    }

    @discardableResult
    func copy(snips: [Snip], model: IOSAppModel) async -> Bool {
        let token = beginCopyRequest()
        let interaction = model.haptics.beginInteraction()
        let current = currentSnips(for: snips, model: model)
        guard !current.isEmpty else { return false }
        let versions = model.copiedSnipVersions(ids: Set(current.map(\.id)))
        let preparation = await makePreparedPayload(snips: current, model: model, use: .copy)
        guard let payload = preparation.payload, !Task.isCancelled else { return false }
        guard isCurrentCopyRequest(token) else { return false }
        guard requireAllFiles(
            in: payload,
            preparationErrorCode: preparation.failureCode,
            versions: versions,
            model: model,
            interaction: interaction
        ) else { return false }
        return await writeAndMarkDone(
            payload.copyItems,
            versions: versions,
            token: token,
            model: model,
            interaction: interaction,
            makeToast: { .copied(count: current.count) }
        )
    }

    @discardableResult
    func copyText(snips: [Snip], model: IOSAppModel) async -> Bool {
        let token = beginCopyRequest()
        let interaction = model.haptics.beginInteraction()
        let current = currentSnips(for: snips, model: model)
        guard !current.isEmpty else { return false }
        let versions = model.copiedSnipVersions(ids: Set(current.map(\.id)))
        return await writeAndMarkDone(
            makePayload(snips: current, model: model).textItems,
            versions: versions,
            token: token,
            model: model,
            interaction: interaction,
            makeToast: { .copiedText() }
        )
    }

    @discardableResult
    func copyAttachments(snips: [Snip], model: IOSAppModel) async -> Bool {
        let token = beginCopyRequest()
        let interaction = model.haptics.beginInteraction()
        let current = currentSnips(for: snips, model: model)
        guard !current.isEmpty else { return false }
        let versions = model.copiedSnipVersions(ids: Set(current.map(\.id)))
        let preparation = await makePreparedPayload(snips: current, model: model, use: .copy)
        guard let payload = preparation.payload, !Task.isCancelled else { return false }
        guard isCurrentCopyRequest(token) else { return false }
        guard requireAllFiles(
            in: payload,
            preparationErrorCode: preparation.failureCode,
            versions: versions,
            model: model,
            interaction: interaction
        ) else { return false }
        guard !payload.attachmentItems.isEmpty else { return false }
        return await writeAndMarkDone(
            payload.attachmentItems,
            versions: versions,
            token: token,
            model: model,
            interaction: interaction,
            makeToast: { .copiedAttachments() }
        )
    }

    func share(snips: [Snip], model: IOSAppModel) async {
        model.haptics.invalidatePendingFeedback()
        let current = currentSnips(for: snips, model: model)
        guard !current.isEmpty else { return }
        let versions = model.copiedSnipVersions(ids: Set(current.map(\.id)))
        let preparation = await makePreparedPayload(snips: current, model: model, use: .export)
        guard let payload = preparation.payload, !Task.isCancelled else { return }
        guard requireAllFiles(
            in: payload,
            preparationErrorCode: preparation.failureCode,
            versions: versions,
            model: model,
            interaction: nil
        ) else { return }
        shareRequest = IOSShareRequest(items: payload.copyItems)
    }

    @discardableResult
    func copyTextFromNotice(_ notice: IOSUnavailableFilesNotice, model: IOSAppModel) async -> Bool {
        let token = beginCopyRequest()
        let interaction = model.haptics.beginInteraction()
        unavailableFilesNotice = nil
        return await writeAndMarkDone(
            notice.payload.textItems,
            versions: notice.versions,
            token: token,
            model: model,
            interaction: interaction,
            makeToast: { .copiedText() }
        )
    }

    @discardableResult
    func toggleDone(snip: Snip, model: IOSAppModel) async -> Bool {
        guard let current = model.snips.first(where: { $0.id == snip.id }), !current.isPinned else {
            return false
        }
        if current.isDone { return await model.toggleDone(id: current.id) }
        return await copy(snips: [current], model: model)
    }

    @discardableResult
    func markDone(snips: [Snip], model: IOSAppModel) async -> Bool {
        let ids = Set(snips.map(\.id))
        let current = model.snips.filter {
            ids.contains($0.id) && !$0.isPinned && !$0.isDone
        }
        guard !current.isEmpty else { return false }
        return await copy(snips: current, model: model)
    }

    func cancelUnavailableFilesNotice() {
        unavailableFilesNotice = nil
    }

    @discardableResult
    func copyClipboardEntry(
        _ entry: ClipboardEntry, clipboard: IOSClipboardModel, model: IOSAppModel? = nil
    ) -> Task<Bool, Never> {
        let token = beginCopyRequest()
        let task = Task {
            let copied = await clipboard.copy(entry)
            if copied, !Task.isCancelled, self.isCurrentCopyRequest(token) {
                model?.presentToast(.copied(count: 1))
            }
            return copied
        }
        copyRequest = .clipboardEntry(token: token, task: task)
        return task
    }

    private func makePayload(snips: [Snip], model: IOSAppModel) -> IOSCopySharePayload {
        payloadBuilder.payload(for: snips, attachmentURL: model.attachmentURL(for:))
    }

    private func currentSnips(for requested: [Snip], model: IOSAppModel) -> [Snip] {
        let currentByID = Dictionary(uniqueKeysWithValues: model.snips.map { ($0.id, $0) })
        return requested.compactMap { currentByID[$0.id] }
    }

    private func beginCopyRequest() -> UUID {
        if case .clipboardEntry(_, let task) = copyRequest { task.cancel() }
        let token = UUID()
        copyRequest = .snips(token: token)
        return token
    }

    private func isCurrentCopyRequest(_ token: UUID) -> Bool {
        copyRequest?.token == token
    }

    private func makePreparedPayload(
        snips: [Snip],
        model: IOSAppModel,
        use: SyncedAttachmentUse
    ) async -> (payload: IOSCopySharePayload?, failureCode: String?) {
        var firstFailureCode: String?
        var cancelled = false
        for attachment in payloadBuilder.uniqueAttachments(in: snips) {
            guard !Task.isCancelled else { return (nil, nil) }
            _ = await model.prepareAttachment(
                attachment.id,
                for: use,
                onFailure: { code in
                    if firstFailureCode == nil { firstFailureCode = code }
                },
                onCancellation: { cancelled = true }
            )
            if cancelled || Task.isCancelled { return (nil, nil) }
        }
        return (makePayload(snips: snips, model: model), firstFailureCode)
    }

    private func requireAllFiles(
        in payload: IOSCopySharePayload,
        preparationErrorCode: String?,
        versions: IOSCopiedSnipVersions,
        model: IOSAppModel,
        interaction: UUID?
    ) -> Bool {
        guard payload.unavailableFileNames.isEmpty else {
            let notice = IOSUnavailableFilesNotice(payload: payload, versions: versions)
            if unavailableFilesNotice?.message != notice.message {
                diagnostics.record(.failure(
                    operation: "attachment.prepare",
                    errorCode: preparationErrorCode ?? "attachment.unavailableAfterPrepare",
                    visibility: .user
                ))
            }
            unavailableFilesNotice = notice
            model.haptics.emit(.warning, for: interaction)
            return false
        }
        unavailableFilesNotice = nil
        return true
    }

    private func writeAndMarkDone(
        _ items: [IOSCopyItem],
        versions: IOSCopiedSnipVersions,
        token: UUID,
        model: IOSAppModel,
        interaction: UUID?,
        makeToast: () -> AppToast
    ) async -> Bool {
        guard isCurrentCopyRequest(token) else { return false }
        guard pasteboard.write(items) else {
            diagnostics.record(.failure(
                operation: "clipboard.write",
                errorCode: "pasteboard.writeFailed",
                visibility: .user
            ))
            let message = String(localized: "Couldn’t copy that content. Try again.")
            model.presentFailure(AppFailure(
                message: message, operation: "clipboard.write", diagnosticCode: "pasteboard.writeFailed"
            ))
            model.haptics.emit(.error, for: interaction)
            return false
        }
        model.clearFailure(for: "clipboard.write")
        let toast = makeToast()
        switch await model.markCopiedSnipsDone(
            versions: versions,
            copyToast: toast,
            ifStillCurrent: { self.isCurrentCopyRequest(token) }
        ) {
        case .unchanged:
            if isCurrentCopyRequest(token) { model.presentToast(makeToast()) }
            model.haptics.emit(.copied, for: interaction)
            return true
        case .markedDone:
            model.haptics.emit([.copied, .markedDone], for: interaction)
            return true
        case .failed:
            model.haptics.emit([.copied, .error], for: interaction)
            return false
        }
    }
}

struct CopyShareActions: View {
    let snips: [Snip]
    let model: IOSAppModel
    let coordinator: IOSCopyShareCoordinator
    let identifierSuffix: String
    var includesCopy = true
    var beforeAction: () -> Void = {}

    private var hasAttachments: Bool {
        snips.contains { !$0.attachments.isEmpty }
    }

    var body: some View {
        if includesCopy {
            Button("Copy", systemImage: "doc.on.doc") {
                beforeAction()
                Task { await coordinator.copy(snips: snips, model: model) }
            }
            .accessibilityIdentifier("copy-\(identifierSuffix)")
        }

        if hasAttachments {
            Button("Copy Text", systemImage: "text.page") {
                beforeAction()
                Task { await coordinator.copyText(snips: snips, model: model) }
            }
            .accessibilityIdentifier("copy-text-\(identifierSuffix)")

            Button("Copy Attachments", systemImage: "paperclip") {
                beforeAction()
                Task { await coordinator.copyAttachments(snips: snips, model: model) }
            }
            .accessibilityIdentifier("copy-attachments-\(identifierSuffix)")
        }

        Button("Share", systemImage: "square.and.arrow.up") {
            beforeAction()
            Task { await coordinator.share(snips: snips, model: model) }
        }
        .accessibilityIdentifier("share-\(identifierSuffix)")
    }
}

struct IOSShareSheetPresenter: UIViewControllerRepresentable {
    @Binding var request: IOSShareRequest?
    var diagnosticOperation: StaticString = "app.user_action"
    var diagnostics: AppDiagnosticRecorder = .live

    @MainActor
    final class Coordinator {
        private enum Phase {
            case idle
            case active(id: UUID, activity: UIActivityViewController, completion: IOSShareCompletion)
            case dismantled
        }

        private var phase = Phase.idle
        private let request: Binding<IOSShareRequest?>

        init(request: Binding<IOSShareRequest?>) { self.request = request }

        fileprivate var isIdle: Bool {
            if case .idle = phase { true } else { false }
        }

        fileprivate func isActive(for id: UUID) -> Bool {
            if case .active(let activeID, _, _) = phase { activeID == id } else { false }
        }

        fileprivate func begin(_ id: UUID, activity: UIActivityViewController, completion: IOSShareCompletion) {
            if case .dismantled = phase { return }
            phase = .active(id: id, activity: activity, completion: completion)
        }

        fileprivate func finish(_ id: UUID) {
            guard isActive(for: id) else { return }
            phase = .idle
        }

        fileprivate func cancel(_ id: UUID) {
            guard case .active(let activeID, _, let completion) = phase, activeID == id else { return }
            completion.finish(.success(.cancelled))
        }

        func tearDown(_ controller: UIViewController) {
            let active: (activity: UIActivityViewController, completion: IOSShareCompletion)?
            switch phase {
            case .dismantled: return
            case .idle: active = nil
            case .active(_, let activity, let completion): active = (activity, completion)
            }
            phase = .dismantled
            // A host can disappear before SwiftUI schedules presentation of a new request.
            let terminal = active?.completion ?? request.wrappedValue?.completion
            let presented = active?.activity
            presented?.completionWithItemsHandler = nil
            // Wait for dismissal before releasing bytes a presented activity may read.
            if controller.presentedViewController != nil {
                controller.dismiss(animated: false) { terminal?.finish(.success(.cancelled)) }
            } else if let presented, presented.presentingViewController != nil {
                presented.dismiss(animated: false) { terminal?.finish(.success(.cancelled)) }
            } else {
                terminal?.finish(.success(.cancelled))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(request: $request) }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.tearDown(controller)
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard let request, controller.presentedViewController == nil, coordinator.isIdle else { return }
        let activity = makeActivityController(for: request, coordinator: coordinator)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX,
                y: controller.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        DispatchQueue.main.async {
            guard coordinator.isActive(for: request.id) else { return }
            guard self.request?.id == request.id, controller.presentedViewController == nil else {
                coordinator.cancel(request.id)
                return
            }
            controller.present(activity, animated: true)
        }
    }

    func makeActivityController(
        for request: IOSShareRequest, coordinator: Coordinator? = nil
    ) -> UIActivityViewController {
        let activity = UIActivityViewController(
            activityItems: request.items.map(shareItem),
            applicationActivities: nil
        )
        let terminal = IOSShareCompletion { [weak coordinator] result in
            if case .failure(let error) = result, request.completion == nil {
                // Awaited diagnostic delivery records at the shared model. Ordinary sharing
                // still records here, through the same private-safe error sanitizer.
                diagnostics.record(.failure(
                    operation: diagnosticOperation, error: error, visibility: .user
                ))
            }
            request.completion?.finish(result)
            coordinator?.finish(request.id)
            guard self.request?.id == request.id else { return }
            self.request = nil
        }
        coordinator?.begin(request.id, activity: activity, completion: terminal)
        activity.completionWithItemsHandler = { _, completed, _, error in
            DispatchQueue.main.async {
                if let error, !isDiagnosticCancellation(error) {
                    terminal.finish(.failure(error))
                } else {
                    terminal.finish(.success(completed && error == nil ? .shared : .cancelled))
                }
            }
        }
        return activity
    }

    private func shareItem(_ item: IOSCopyItem) -> Any {
        switch item {
        case .text(let text): text as NSString
        case .file(let url): url
        }
    }
}
