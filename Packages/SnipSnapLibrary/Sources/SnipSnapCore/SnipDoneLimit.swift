import Foundation

/// A per-device presentation choice. Saved snips and search results remain intact.
public enum SnipDoneLimit: Int, CaseIterable, Sendable {
    case ten = 10
    case twentyFive = 25
    case fifty = 50
    case unlimited = 0

    private static let defaultsKey = "snipDoneDisplayLimit"

    public static func load(from defaults: UserDefaults) -> Self {
        guard let value = defaults.object(forKey: defaultsKey) as? Int else { return .ten }
        return Self(rawValue: value) ?? .ten
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    public func apply(to orderedSnips: [Snip], completionFilter: SnipCompletionFilter = .all, query: String = "") -> [Snip] {
        guard completionFilter == .all, self != .unlimited, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return orderedSnips }
        var doneCount = 0
        return orderedSnips.filter { snip in
            guard snip.isDone, !snip.isPinned else { return true }
            doneCount += 1
            return doneCount <= rawValue
        }
    }
}
