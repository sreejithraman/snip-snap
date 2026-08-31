import Foundation
import SnipSnapCore

enum AppDataPaths {
    static func clipboardHistory(fileManager: FileManager = .default) -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["SNIP_SNAP_STORE_PATH"],
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: false)
                .deletingLastPathComponent()
                .appendingPathComponent("clipboard.json", isDirectory: false)
        }
        return appSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("clipboard.json", isDirectory: false)
    }

    private static func appSupportDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Snip Snap", isDirectory: true)
    }
}
