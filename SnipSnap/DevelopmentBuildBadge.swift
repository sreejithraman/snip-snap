import SwiftUI

enum DevelopmentBadgeTone: CaseIterable, Equatable {
    case red
    case orange
    case yellow
    case green
    case blue
    case indigo
    case violet
    case black
    case white

    func usesDarkLabel(in colorScheme: ColorScheme) -> Bool {
        switch self {
        case .black:
            false
        case .indigo:
            colorScheme == .dark
        default:
            true
        }
    }
}

struct DevelopmentBuildIdentity: Equatable {
    private static let bundleIdentifierPrefix = "world.sree.snipsnap.dev"

    let slot: Int

    init?(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              bundleIdentifier.hasPrefix(Self.bundleIdentifierPrefix) else {
            return nil
        }

        let suffix = bundleIdentifier.dropFirst(Self.bundleIdentifierPrefix.count)
        guard let slot = Int(suffix), slot > 0, String(slot) == suffix else { return nil }
        self.slot = slot
    }

    static var current: DevelopmentBuildIdentity? {
        DevelopmentBuildIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    var badgeTitle: String { "DEV \(slot)" }

    var badgeTone: DevelopmentBadgeTone {
        let index = (slot - 1) % DevelopmentBadgeTone.allCases.count
        return DevelopmentBadgeTone.allCases[index]
    }
}

struct DevelopmentBuildBadge: View {
    private static let trailingOverhang: CGFloat = 5
    private static let topLift: CGFloat = 2

    static let panelXOffset = -(AppWindowDefaults.effectGutter - trailingOverhang)
    static let panelYOffset = AppWindowDefaults.effectGutter - topLift

    let identity: DevelopmentBuildIdentity

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(identity.badgeTitle)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(
                SnipSnapColors.developmentBadgeLabel(
                    tone: identity.badgeTone,
                    colorScheme: colorScheme
                )
            )
            .padding(.horizontal, 4)
            .frame(height: 12)
            .background(
                SnipSnapColors.developmentBadge(tone: identity.badgeTone),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        SnipSnapColors.developmentBadgeEdge(tone: identity.badgeTone),
                        lineWidth: 0.5
                    )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
