import Foundation

extension ComposerDraftStore {
    func stageScreenCapture() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Snip Snap Capture \(UUID().uuidString).png")
    }

    func finishScreenCapture(_ url: URL, in listID: UUID, succeeded: Bool) {
        guard succeeded, FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        addTemporary(url, to: listID)
    }
}
