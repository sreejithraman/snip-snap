import Foundation

enum InteractiveScreenCapture {
    /// macOS owns capture consent and selection. Cancellation or denied access returns false.
    static func capture(to destination: URL) async throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", destination.path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        return status == 0 && FileManager.default.fileExists(atPath: destination.path)
    }
}
