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
    }

    var content = ""
    var attachments: [ShareImportAttachment] = []
    var lists: [SnipList] = [.inbox]
    var destinationListID = SnipList.inboxID
    private(set) var phase: Phase = .loading

    private let extensionContext: NSExtensionContext
    private let imports: ShareImportStore
    private let staging: ShareImportStagingArea
    private let defaults: UserDefaults
    private var isCanceled = false

    init?(
        extensionContext: NSExtensionContext,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        guard let container = SnipSnapAppGroupContainer.resolve(
                bundle: bundle,
                fileManager: fileManager
            ),
            let staging = try? ShareImportStagingArea(sharedRootURL: container.url)
        else { return nil }
        self.extensionContext = extensionContext
        imports = ShareImportStore(sharedRootURL: container.url)
        self.staging = staging
        defaults = UserDefaults(suiteName: container.identifier) ?? .standard
    }

    var canSave: Bool {
        phase == .editing
            && (!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    func load() async {
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
            guard !isCanceled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        isCanceled = true
        staging.discard()
        extensionContext.cancelRequest(
            withError: NSError(
                domain: NSCocoaErrorDomain,
                code: NSUserCancelledError
            )
        )
    }

    func save() async {
        guard canSave else { return }
        phase = .saving
        let request = ShareImportRequest(
            content: content,
            destinationListID: destinationListID,
            attachments: attachments,
            requestID: staging.requestID
        )
        do {
            _ = try await imports.save(request)
            defaults.set(destinationListID.uuidString, forKey: Self.destinationKey)
            extensionContext.completeRequest(returningItems: nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static let destinationKey = "share.lastDestinationListID"
}
