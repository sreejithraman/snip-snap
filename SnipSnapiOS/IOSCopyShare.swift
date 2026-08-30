import Foundation
import Observation
import SnipSnapCore
import SwiftUI
import UIKit

enum IOSCopyItem: Equatable {
    case text(String)
    case file(URL)
}

struct IOSCopySharePayload: Equatable {
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
    private var currentLease: IOSPasteboardFileLease?
    private var leasedChangeCount: Int?

    var activeLeaseDirectory: URL? {
        currentLease?.directory
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
        restoreCurrentLease()
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
                providers.append(provider)
            }
        }
        pasteboard.setItemProviders(
            providers,
            localOnly: false,
            expirationDate: nil
        )
        currentLease?.remove()
        currentLease = staged.lease
        leasedChangeCount = staged.lease == nil ? nil : pasteboard.changeCount
        if let lease = staged.lease, let leasedChangeCount {
            lease.record(
                pasteboardName: pasteboard.name.rawValue,
                changeCount: leasedChangeCount
            )
        }
        removeStaleLeases(keeping: staged.lease?.directory)
        return true
    }

    @objc private func pasteboardChanged() {
        guard let leasedChangeCount, pasteboard.changeCount != leasedChangeCount else { return }
        releaseCurrentLease()
    }

    @objc private func pasteboardRemoved(_ notification: Notification) {
        let removedName = (notification.object as? UIPasteboard.Name)
            ?? (notification.object as? UIPasteboard)?.name
        guard removedName == pasteboard.name else { return }
        releaseCurrentLease()
    }

    private func releaseCurrentLease() {
        currentLease?.remove()
        currentLease = nil
        leasedChangeCount = nil
    }

    private func restoreCurrentLease() {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil
        ) else { return }
        for directory in directories {
            guard let record = IOSPasteboardFileLease.record(in: directory) else {
                continue
            }
            guard record.pasteboardName == pasteboard.name.rawValue else { continue }
            if record.changeCount == pasteboard.changeCount, currentLease == nil {
                currentLease = IOSPasteboardFileLease(
                    directory: directory,
                    fileManager: fileManager
                )
                leasedChangeCount = record.changeCount
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

struct IOSUnavailableFilesNotice: Identifiable, Equatable {
    let id = UUID()
    let payload: IOSCopySharePayload

    var message: String {
        let names = payload.unavailableFileNames.joined(separator: ", ")
        return names.isEmpty
            ? "One or more files could not be read."
            : "These files could not be read: \(names)"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.payload == rhs.payload
    }
}

struct IOSShareRequest: Identifiable, Equatable {
    let id = UUID()
    let items: [IOSCopyItem]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items
    }
}

@MainActor
@Observable
final class IOSCopyShareCoordinator {
    private let pasteboard: any IOSPasteboardWriting
    private let payloadBuilder: IOSCopySharePayloadBuilder

    var unavailableFilesNotice: IOSUnavailableFilesNotice?
    var shareRequest: IOSShareRequest?
    var errorMessage: String?
    var statusMessage: String?

    init(
        pasteboard: any IOSPasteboardWriting = IOSSystemPasteboard(),
        payloadBuilder: IOSCopySharePayloadBuilder = IOSCopySharePayloadBuilder()
    ) {
        self.pasteboard = pasteboard
        self.payloadBuilder = payloadBuilder
    }

    func copy(snips: [Snip], model: IOSAppModel) async {
        let payload = await makePreparedPayload(snips: snips, model: model, use: .copy)
        guard requireAllFiles(in: payload) else { return }
        write(payload.copyItems, status: "Copied")
    }

    func copyText(snips: [Snip], model: IOSAppModel) {
        write(makePayload(snips: snips, model: model).textItems, status: "Copied Text")
    }

    func copyAttachments(snips: [Snip], model: IOSAppModel) async {
        let payload = await makePreparedPayload(snips: snips, model: model, use: .copy)
        guard requireAllFiles(in: payload) else { return }
        write(payload.attachmentItems, status: "Copied Attachments")
    }

    func share(snips: [Snip], model: IOSAppModel) async {
        let payload = await makePreparedPayload(snips: snips, model: model, use: .export)
        guard requireAllFiles(in: payload) else { return }
        shareRequest = IOSShareRequest(items: payload.copyItems)
    }

    func copyTextFromNotice() {
        guard let notice = unavailableFilesNotice else { return }
        unavailableFilesNotice = nil
        write(notice.payload.textItems, status: "Copied Text")
    }

    func cancelUnavailableFilesNotice() {
        unavailableFilesNotice = nil
    }

    private func makePayload(snips: [Snip], model: IOSAppModel) -> IOSCopySharePayload {
        payloadBuilder.payload(for: snips, attachmentURL: model.attachmentURL(for:))
    }

    private func makePreparedPayload(
        snips: [Snip],
        model: IOSAppModel,
        use: SyncedAttachmentUse
    ) async -> IOSCopySharePayload {
        for attachment in payloadBuilder.uniqueAttachments(in: snips) {
            _ = await model.prepareAttachment(attachment.id, for: use)
        }
        return makePayload(snips: snips, model: model)
    }

    private func requireAllFiles(in payload: IOSCopySharePayload) -> Bool {
        guard payload.unavailableFileNames.isEmpty else {
            unavailableFilesNotice = IOSUnavailableFilesNotice(payload: payload)
            return false
        }
        unavailableFilesNotice = nil
        return true
    }

    private func write(_ items: [IOSCopyItem], status: String) {
        guard pasteboard.write(items) else {
            errorMessage = "Snip Snap could not copy that content."
            return
        }
        errorMessage = nil
        statusMessage = status
    }
}

struct CopyShareActions: View {
    let snips: [Snip]
    let model: IOSAppModel
    let coordinator: IOSCopyShareCoordinator
    let identifierSuffix: String

    private var hasAttachments: Bool {
        snips.contains { !$0.attachments.isEmpty }
    }

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc") {
            Task { await coordinator.copy(snips: snips, model: model) }
        }
        .accessibilityIdentifier("copy-\(identifierSuffix)")

        Button("Copy Text", systemImage: "text.page") {
            coordinator.copyText(snips: snips, model: model)
        }
        .accessibilityIdentifier("copy-text-\(identifierSuffix)")

        Button("Copy Attachments", systemImage: "paperclip") {
            Task { await coordinator.copyAttachments(snips: snips, model: model) }
        }
        .disabled(!hasAttachments)
        .accessibilityIdentifier("copy-attachments-\(identifierSuffix)")

        Button("Share", systemImage: "square.and.arrow.up") {
            Task { await coordinator.share(snips: snips, model: model) }
        }
        .accessibilityIdentifier("share-\(identifierSuffix)")
    }
}

struct IOSShareSheetPresenter: UIViewControllerRepresentable {
    @Binding var request: IOSShareRequest?

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let request, controller.presentedViewController == nil else { return }
        let activity = UIActivityViewController(
            activityItems: request.items.map(shareItem),
            applicationActivities: nil
        )
        activity.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { self.request = nil }
        }
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
            guard controller.presentedViewController == nil else { return }
            controller.present(activity, animated: true)
        }
    }

    private func shareItem(_ item: IOSCopyItem) -> Any {
        switch item {
        case .text(let text): text as NSString
        case .file(let url): url
        }
    }
}
