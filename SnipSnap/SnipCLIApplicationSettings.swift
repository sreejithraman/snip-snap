import SnipSnapCore

/// Shared by application command handling and settings contract tests; storage stays with each existing model.
@MainActor
enum SnipCLIApplicationSettings {
    static func apply(
        _ key: SnipCLIApplicationSetting, value: String, model: AppModel,
        updates: UpdateChannelSettings, updatesAvailable: Bool,
        resetUpdateCycle: () -> Void = {}
    ) throws {
        guard model.editingID == nil else { throw SnipCLIRequestError.editingInProgress }
        guard key.accepts(value) else { throw SnipLibraryError.invalidCommand }
        switch key {
        case .appearance: model.setAppearance(AppAppearance(rawValue: value)!)
        case .sort: model.setSortMode(SnipSortMode(rawValue: value)!)
        case .completionFilter: model.completionFilter = SnipCompletionFilter(rawValue: value)!
        case .clipboardOnlyPinned: model.clipboardViewOptions.onlyPinned = value == "on"
        case .clipboardNewestFirst: model.clipboardViewOptions.newestFirst = value == "on"
        case .betaUpdates:
            guard updatesAvailable else { throw SnipLibraryError.transferUnsupported }
            updates.setIncludesBetaUpdates(value == "on", resetUpdateCycle: resetUpdateCycle)
        }
    }
}
