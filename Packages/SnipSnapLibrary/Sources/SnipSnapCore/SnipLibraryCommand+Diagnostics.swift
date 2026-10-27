import Foundation

public extension SnipLibraryCommand {
  var diagnosticOperation: StaticString {
    switch self {
    case .add: "snip.add"
    case .update: "snip.update"
    case .editAttachments: "snip.edit_attachments"
    case .createList: "list.create"
    case .restoreList: "list.restore"
    case .updateList: "list.update"
    case .deleteList: "list.delete"
    case .moveList: "list.move"
    case .delete: "snip.delete"
    case .restore, .restoreReplacing: "snip.restore"
    case .merge: "snip.merge"
    case .setPinned, .togglePinned: "snip.pin"
    case .setDone, .toggleDone, .toggleDoneMany: "snip.completion"
    case .moveChronologically, .place: "snip.move"
    case .replaceAll: "snip.replace_all"
    case .applyDevicePatch: "library.apply_patch"
    case .pruneAttachments: "attachment.prune"
    case .batch: "library.batch"
    case .guarded(_, let command): command.diagnosticOperation
    }
  }
}
