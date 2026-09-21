import SwiftUI

enum AgentSnipContextLanguage {
    static func accessibilityLabel(_ contextLabel: String?) -> String {
        guard let contextLabel else { return String(localized: "Agent") }
        return String(localized: "Agent, \(contextLabel)")
    }
}

struct AgentSnipContextLabel: View {
    let contextLabel: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.caption2)
                .accessibilityHidden(true)
            if let contextLabel {
                Text(contextLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("agent-context-label")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentSnipContextLanguage.accessibilityLabel(contextLabel))
    }
}
