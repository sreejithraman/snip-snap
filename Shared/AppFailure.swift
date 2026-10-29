import Foundation
import SnipSnapCore

struct AppFailure: Identifiable, Equatable, Sendable {
    enum Surface: Equatable, Sendable {
        case snackbar
        case inline
        case dialog
    }

    let id = UUID()
    let title: String
    let message: String
    let operation: String
    let code: String
    let occurredAt = Date()

    init(error: any Error, operation: StaticString, title: String? = nil) {
        self.init(message: error.localizedDescription,
                  title: title ?? (error as? SnipLibraryError == .duplicateList
                    ? String(localized: "Name Already Used") : nil),
                  operation: operation, diagnosticCode: diagnosticErrorCode(error))
    }

    init(message: String, title: String? = nil, operation: StaticString, diagnosticCode: String) {
        self.operation = String(describing: operation)
        self.message = message
        self.code = diagnosticCode
        self.title = title ?? Self.title(for: String(describing: operation))
    }

    var surface: Surface {
        if operation == "snip.add" || operation == "snip.update"
            || operation == "snip.edit_attachments" || operation == "snip.paste_save"
            || operation.hasPrefix("composer.") || operation == "list.create" || operation == "list.update"
            || operation.hasPrefix("attachment.import_")
            || operation.hasPrefix("backup.") || operation.hasPrefix("diagnostics.")
            || operation.hasPrefix("shortcut.") || operation == "recovery.resolve" {
            return .inline
        }
        switch operation {
        case "snip.completion", "snip.completion_after_copy", "snip.pin", "snip.move", "snip.merge", "snip.delete",
             "list.delete",
             "attachment.prepare", "attachment.cache_clear", "selection.capture", "capture.screen":
            return .snackbar
        default:
            return operation.hasPrefix("clipboard.") ? .snackbar : .dialog
        }
    }

    var diagnosticReport: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        // Localized errors may contain content or file paths. Copy only structured diagnostics.
        return """
        Snip Snap error details
        App: \(version) (\(build))
        System: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Time: \(occurredAt.ISO8601Format())
        Operation: \(operation)
        Error code: \(code)
        Reference: \(id.uuidString)
        """
    }

    private static func title(for operation: String) -> String {
        switch operation {
        case "snip.add", "snip.update", "snip.paste_save", "snip.edit_attachments": String(localized: "Couldn’t save snip")
        case "snip.completion": String(localized: "Couldn’t change Done")
        case "snip.completion_after_copy": String(localized: "Copied, but couldn’t mark Done")
        case "snip.delete": String(localized: "Couldn’t delete snip")
        case "snip.undo_delete", "snip.undo_done": String(localized: "Couldn’t undo")
        case "snip.pin", "clipboard.pin": String(localized: "Couldn’t update pin")
        case "snip.move": String(localized: "Couldn’t move snip")
        case "snip.merge": String(localized: "Couldn’t merge snips")
        case "clipboard.write", "clipboard.copy_file", "clipboard.export": String(localized: "Couldn’t copy")
        case "clipboard.delete": String(localized: "Couldn’t delete clipboard entry")
        case "clipboard.clear": String(localized: "Couldn’t clear clipboard history")
        case "list.create": String(localized: "Couldn’t create list")
        case "list.update": String(localized: "Couldn’t update list")
        case "list.delete": String(localized: "Couldn’t delete list")
        case "selection.capture", "capture.screen": String(localized: "Couldn’t snip")
        case "attachment.prepare": String(localized: "Couldn’t prepare attachments")
        case "attachment.cache_clear": String(localized: "Couldn’t clear downloaded files")
        default: String(localized: "Something Went Wrong")
        }
    }
}
