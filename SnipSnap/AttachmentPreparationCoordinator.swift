import Foundation
import SnipSnapCore

@MainActor
final class AttachmentPreparationCoordinator {
    private var cachedURLs: [UUID: URL] = [:]
    private var cloudSyncHandler: (any OptionalCloudSyncHandling)?

    init(cloudSyncHandler: (any OptionalCloudSyncHandling)?) {
        self.cloudSyncHandler = cloudSyncHandler
    }

    func setCloudSyncHandler(_ handler: (any OptionalCloudSyncHandling)?) {
        cloudSyncHandler = handler
    }

    func cachedURL(for attachment: SnipAttachment) -> URL? {
        cachedURLs[attachment.id]
    }

    func replaceCachedURLs(with urls: [UUID: URL]) {
        cachedURLs = urls
    }

    func prepare(
        _ attachments: [SnipAttachment],
        for use: SyncedAttachmentUse
    ) async throws -> [UUID: URL] {
        var prepared: [UUID: URL] = [:]
        for attachment in unique(attachments) {
            if let cached = cachedURLs[attachment.id], isAvailable(cached) {
                prepared[attachment.id] = cached
                continue
            }
            cachedURLs[attachment.id] = nil
            guard let cloudSyncHandler else {
                throw SnipLibraryError.attachmentCopyFailed
            }
            let url = try await cloudSyncHandler.prepareSyncedAttachment(
                attachment.id,
                for: use
            )
            cachedURLs[attachment.id] = url
            prepared[attachment.id] = url
        }
        return prepared
    }

    func preparePreview(
        _ attachments: [SnipAttachment],
        selected: SnipAttachment
    ) async throws -> (urls: [URL], selectedURL: URL)? {
        let prepared = try await prepare(attachments, for: .preview)
        let urls = unique(attachments).compactMap { prepared[$0.id] }
        guard let selectedURL = prepared[selected.id] else { return nil }
        return (urls, selectedURL)
    }

    func unique(_ attachments: [SnipAttachment]) -> [SnipAttachment] {
        var seen: Set<UUID> = []
        return attachments.filter { seen.insert($0.id).inserted }
    }

    func clearDownloadedFiles() async throws {
        guard let cloudSyncHandler else { throw SnipLibraryError.transferUnsupported }
        try await cloudSyncHandler.clearDownloadedFiles()
    }

    private func isAvailable(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
