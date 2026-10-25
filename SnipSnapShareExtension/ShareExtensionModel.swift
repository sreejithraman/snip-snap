import Foundation
import Observation
import SnipSnapCore
import SnipSnapPersistence

@MainActor
@Observable
final class ShareExtensionModel {
    enum Phase: Equatable {
        case loading
        case editing
        case saving
        case failed(String)
        case unavailable
        case cancelled
    }

    var content = ""
    var attachments: [ShareImportAttachment] = []
    var lists: [SnipList] = [.inbox]
    var destinationListID = SnipList.inboxID
    private(set) var phase: Phase = .loading

    var destinationList: SnipList? {
        lists.first { $0.id == destinationListID }
    }

    private let extensionContext: NSExtensionContext
    private let imports: ShareImportStore?
    private let staging: ShareImportStagingArea?
    private let diagnostics: AppDiagnosticRecorder
    private let saveImport: (@MainActor (ShareImportRequest) async throws -> Void)?
    private let defaults: UserDefaults
    private var isCanceled = false

    convenience init(
        extensionContext: NSExtensionContext,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        let container = SnipSnapAppGroupContainer.resolve(bundle: bundle, fileManager: fileManager)
        self.init(
            extensionContext: extensionContext,
            sharedRootURL: container?.url,
            defaults: container.flatMap { UserDefaults(suiteName: $0.identifier) } ?? .standard
        )
    }

    // Only filesystem/provider publication effects vary in native tests. The model still
    // runs the real input loader and import store unless a failing effect is supplied.
    init(
        extensionContext: NSExtensionContext,
        sharedRootURL: URL?,
        defaults: UserDefaults = .standard,
        diagnostics: AppDiagnosticRecorder = .live,
        makeStaging: (URL) throws -> ShareImportStagingArea = { try ShareImportStagingArea(sharedRootURL: $0) },
        saveImport: (@MainActor (ShareImportRequest) async throws -> Void)? = nil
    ) {
        self.extensionContext = extensionContext
        self.defaults = defaults
        self.diagnostics = diagnostics
        self.saveImport = saveImport
        guard let sharedRootURL else {
            imports = nil
            staging = nil
            phase = .unavailable
            diagnostics.record(.failure(operation: "share.extension_startup",
                errorCode: "share.sharedContainerUnavailable", visibility: .user))
            return
        }
        imports = ShareImportStore(sharedRootURL: sharedRootURL)
        do {
            staging = try makeStaging(sharedRootURL)
        } catch {
            staging = nil
            phase = .failed(error.localizedDescription)
            if !isDiagnosticCancellation(error) {
                diagnostics.record(.failure(operation: "share.extension_startup", error: error, visibility: .user))
            }
        }
    }

    var canSave: Bool {
        phase == .editing
            && (!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    func load() async {
        guard phase == .loading, let imports, let staging else {
            _ = await diagnostics.flush(timeout: 0.5)
            return
        }
        do {
            await imports.removeAbandonedIntake()
            let loaded = try await ShareExtensionInputLoader.load(
                items: extensionContext.inputItems.compactMap { $0 as? NSExtensionItem },
                staging: staging
            )
            let loadedLists = await imports.availableLists()
            guard !isCanceled, !Task.isCancelled else {
                staging.discard()
                return
            }
            content = loaded.text
            attachments = loaded.attachments
            lists = loadedLists
            let rememberedID = defaults.string(forKey: Self.destinationKey)
                .flatMap(UUID.init(uuidString:))
            destinationListID = SnipShareDestination.resolve(
                rememberedListID: rememberedID,
                in: lists
            )
            phase = .editing
        } catch {
            staging.discard()
            guard !isCanceled, !Task.isCancelled else { return }
            if isDiagnosticCancellation(error) {
                cancel()
                return
            }
            diagnostics.record(.failure(operation: "share.extension_load", error: error, visibility: .user))
            _ = await diagnostics.flush(timeout: 0.5)
            guard !isCanceled, !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        guard !isCanceled else { return }
        isCanceled = true
        phase = .cancelled
        staging?.discard()
        Task {
            // Keep the extension alive for a finite best-effort write window before
            // asking the host to finish. This never blocks the main actor on disk.
            _ = await diagnostics.flush(timeout: 0.5)
            extensionContext.cancelRequest(withError: CocoaError(.userCancelled))
        }
    }

    func save() async {
        guard canSave, !isCanceled, !Task.isCancelled, let imports, let staging else { return }
        phase = .saving
        let request = ShareImportRequest(
            content: content,
            destinationListID: destinationListID,
            attachments: attachments,
            requestID: staging.requestID
        )
        do {
            if let saveImport { try await saveImport(request) }
            else { _ = try await imports.save(request) }
            _ = await diagnostics.flush(timeout: 0.5)
            guard !isCanceled, !Task.isCancelled else { return }
            defaults.set(destinationListID.uuidString, forKey: Self.destinationKey)
            extensionContext.completeRequest(returningItems: nil)
        } catch {
            guard !isCanceled else { return }
            if Task.isCancelled || isDiagnosticCancellation(error) {
                phase = .editing
                return
            }
            diagnostics.record(.failure(operation: "share.extension_save", error: error, visibility: .user))
            _ = await diagnostics.flush(timeout: 0.5)
            guard !isCanceled, !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
    private static let destinationKey = "share.lastDestinationListID"
}
