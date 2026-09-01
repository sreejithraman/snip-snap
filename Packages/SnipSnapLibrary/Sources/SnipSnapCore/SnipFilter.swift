import Foundation

public enum SnipFilter {
    public static func apply(
        snips: [Snip],
        query: String,
        completionFilter: SnipCompletionFilter,
        listNames: [UUID: String] = [:],
        sourceLabel: (Snip) -> String = {
            guard let label = $0.source?.conciseLabel, !label.isEmpty else {
                return $0.origin.rawValue
            }
            return label
        }
    ) -> [Snip] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snips.filter { snip in
            switch completionFilter {
            case .all:
                break
            case .done:
                guard snip.isDone else { return false }
            case .notDone:
                guard !snip.isDone else { return false }
            }
            guard !needle.isEmpty else { return true }
            return snip.content.localizedCaseInsensitiveContains(needle)
                || snip.attachments.contains {
                    $0.fileName.localizedCaseInsensitiveContains(needle)
                }
                || listNames[snip.listID]?.localizedCaseInsensitiveContains(needle) == true
                || sourceLabel(snip).localizedCaseInsensitiveContains(needle)
                || snip.source?.url?.localizedCaseInsensitiveContains(needle) == true
        }
    }
}
