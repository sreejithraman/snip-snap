import Combine
import Sparkle
import SwiftUI

@MainActor
final class UpdateChannelSettings: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let includesBetaUpdatesKey = "includesBetaUpdates"

    @Published private(set) var includesBetaUpdates: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        includesBetaUpdates = defaults.bool(forKey: Self.includesBetaUpdatesKey)
        super.init()
    }

    var selectedChannels: Set<String> {
        includesBetaUpdates ? ["beta"] : []
    }

    func setIncludesBetaUpdates(
        _ includesBetaUpdates: Bool,
        resetUpdateCycle: () -> Void = { }
    ) {
        guard self.includesBetaUpdates != includesBetaUpdates else { return }
        self.includesBetaUpdates = includesBetaUpdates
        defaults.set(includesBetaUpdates, forKey: Self.includesBetaUpdatesKey)
        resetUpdateCycle()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        selectedChannels
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var settings: UpdateChannelSettings
    let updater: SPUUpdater

    var body: some View {
        Form {
            Toggle(
                "Include beta updates",
                isOn: Binding(
                    get: { settings.includesBetaUpdates },
                    set: { newValue in
                        settings.setIncludesBetaUpdates(newValue) {
                            updater.resetUpdateCycleAfterShortDelay()
                        }
                    }
                )
            )
            .accessibilityIdentifier("include-beta-updates")

            Text("Beta updates may be less stable. Turn this off to receive only normal releases.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}
