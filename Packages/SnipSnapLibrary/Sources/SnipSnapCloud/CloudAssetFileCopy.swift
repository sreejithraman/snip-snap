import Foundation
import SnipSnapPersistence

package enum CloudAssetFileCopy {
    package static func copy(
        recordID: CloudRecordID,
        field: String,
        source: URL,
        destination: CloudAssetDestination
    ) throws -> CloudAssetReceipt {
        let fileManager = FileManager.default
        let finalURL = destination.directoryURL
            .appendingPathComponent("cloud-asset-\(UUID().uuidString)", isDirectory: false)
        guard source.isFileURL, finalURL.deletingLastPathComponent() == destination.directoryURL else {
            throw CloudRecordError.invalidAssetDestination
        }

        do {
            let copied = try AttachmentFileIO.copyRegularFile(
                from: source,
                to: finalURL
            )
            try DurableFile.excludeFromBackup(finalURL)
            return CloudAssetReceipt(
                recordID: recordID,
                field: field,
                fileURL: finalURL,
                byteCount: copied.byteCount,
                sha256: copied.digest
            )
        } catch {
            try? fileManager.removeItem(at: finalURL)
            throw error
        }
    }
}
