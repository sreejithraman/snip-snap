import CryptoKit
import Foundation

package enum CloudAssetFileCopy {
    package static func copy(
        recordID: CloudRecordID,
        field: String,
        source: URL,
        destination: CloudAssetDestination
    ) throws -> CloudAssetReceipt {
        let fileManager = FileManager.default
        let temporaryURL = destination.directoryURL
            .appendingPathComponent(".cloud-asset-\(UUID().uuidString).tmp", isDirectory: false)
        let finalURL = destination.directoryURL
            .appendingPathComponent("cloud-asset-\(UUID().uuidString)", isDirectory: false)
        guard source.isFileURL, finalURL.deletingLastPathComponent() == destination.directoryURL else {
            throw CloudRecordError.invalidAssetDestination
        }

        fileManager.createFile(atPath: temporaryURL.path, contents: nil)
        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: temporaryURL)
            defer {
                try? input.close()
                try? output.close()
            }
            var hash = SHA256()
            var byteCount: Int64 = 0
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                hash.update(data: chunk)
                byteCount += Int64(chunk.count)
            }
            try output.synchronize()
            try input.close()
            try output.close()
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
            return CloudAssetReceipt(
                recordID: recordID,
                field: field,
                fileURL: finalURL,
                byteCount: byteCount,
                sha256: Data(hash.finalize())
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            try? fileManager.removeItem(at: finalURL)
            throw error
        }
    }
}
