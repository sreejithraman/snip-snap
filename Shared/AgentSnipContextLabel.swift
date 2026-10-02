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
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .accessibilityHidden(true)
            Text("Agent")
                .fontWeight(.medium)
            if let contextLabel {
                Text("·").accessibilityHidden(true)
                Text(contextLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .accessibilityIdentifier("agent-context-label")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentSnipContextLanguage.accessibilityLabel(contextLabel))
    }
}

/// Content stays primary; origin context and update time form a quiet footer.
struct SnipRowMetadata: View {
    let date: Date
    let isPinned: Bool
    var isAgent = false
    var agentContextLabel: String? = nil
    var isRecovered = false
    var showsPin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isAgent {
                AgentSnipContextLabel(contextLabel: agentContextLabel)
            }
            HStack(spacing: 6) {
                if isPinned && showsPin {
                    Image(systemName: "pin.fill")
                        .accessibilityLabel("Pinned")
                }
                Text(date, format: .relative(presentation: .named))
                if isRecovered {
                    Label("Recovered", systemImage: "arrow.uturn.backward.circle.fill")
                        .fontWeight(.medium)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
