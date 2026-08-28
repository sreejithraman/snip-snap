import Foundation

public enum SnipFormatter {
    public static func formatForClipboard(snips: [Snip]) -> String {
        guard snips.count != 1 else { return snips[0].content }
        return formatAsList(snips: snips)
    }

    public static func format(snips: [Snip]) -> String {
        sorted(snips)
            .map(format)
            .joined(separator: "\n\n---\n\n")
    }

    public static func formatInGivenOrder(snips: [Snip]) -> String {
        snips
            .map(format)
            .joined(separator: "\n\n---\n\n")
    }

    private static func formatAsList(snips: [Snip]) -> String {
        sorted(snips)
            .map { snip in
                let indented = format(snip).replacingOccurrences(of: "\n", with: "\n  ")
                return "- \(indented)"
            }
            .joined(separator: "\n")
    }

    private static func sorted(_ snips: [Snip]) -> [Snip] {
        snips.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func format(_ snip: Snip) -> String {
        var parts = [snip.content]
        if let source = snip.source {
            let label = source.conciseLabel
            if !label.isEmpty {
                parts.append("Source: \(label)")
            }
            if let url = source.url, !url.isEmpty {
                parts.append("URL: \(url)")
            }
        }
        return parts.joined(separator: "\n")
    }
}
