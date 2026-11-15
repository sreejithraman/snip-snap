import CoreGraphics

/// The width the list column keeps while it shows names. A width snapped to a hinge follows the
/// hinge, so the column fills the left panel in book pose and returns there after the device goes flat.
enum LibrarySidebarExpandedWidth: Equatable, RawRepresentable {
    case points(CGFloat)
    case hinge

    static let `default` = Self.points(240)
    private static let hingeToken = "hinge"

    init?(rawValue: String) {
        if rawValue == Self.hingeToken {
            self = .hinge
        } else if let points = Double(rawValue), points.isFinite, points > 0 {
            self = .points(CGFloat(points))
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .hinge: Self.hingeToken
        case .points(let points): String(Int(points.rounded()))
        }
    }
}

/// How a device's list column starts and how wide it may grow when flat. iPad starts with names
/// shown in a wider column; phone panels, such as the open iPhone Duo, start on the thin rail.
struct LibrarySidebarDefaults: Equatable {
    let showsNames: Bool
    let expandedWidth: LibrarySidebarExpandedWidth
    let flatMaximumWidth: CGFloat

    static let phone = Self(showsNames: false, expandedWidth: .default, flatMaximumWidth: 320)
    /// 360 pt fits an 11" iPad in landscape and both 13" orientations; 40% of an 11" iPad in portrait is 333.
    static let pad = Self(showsNames: true, expandedWidth: .points(300), flatMaximumWidth: 360)
}

/// The list column's sizing rules inside the view that holds it and its detail. The column is a
/// thin rail, or a sidebar that shows names between a minimum width and a maximum the container sets.
struct LibrarySidebarSizing: Equatable {
    static let railWidth: CGFloat = 80
    static let minimumExpandedWidth: CGFloat = 200
    /// A release predicted below this width snaps to the rail; above it, the column shows names.
    static let railSnapThreshold: CGFloat = 140
    static let flatMaximumFraction: CGFloat = 0.4
    static let hingeDetentDistance: CGFloat = 32
    /// A drag that travels no farther than this is a touch, not a resize.
    static let noChangeTravel: CGFloat = 4
    /// The farthest a drag stretches the column past either end.
    static let rubberBandReach: CGFloat = 30

    /// An unmeasured container leaves the flat maximum at its fixed cap.
    static func unmeasured(_ defaults: LibrarySidebarDefaults = .phone) -> Self {
        Self(containerWidth: .infinity, hingeEdge: nil, flatMaximumWidth: defaults.flatMaximumWidth)
    }

    /// What the column shows: the rail, or names at an expanded width.
    enum Outcome: Equatable {
        case rail
        case expanded(LibrarySidebarExpandedWidth)
    }

    let containerWidth: CGFloat
    /// The leading edge of a vertical hinge inside the container, as in a book pose.
    let hingeEdge: CGFloat?
    /// The widest the column grows without a hinge, before the container's share limits it.
    let flatMaximumWidth: CGFloat

    /// Reads the hinge from a container's division regions. Only a vertical band strictly inside
    /// the container counts. The Duo reports a division's margins inside its frame (20 + 20 pt on a
    /// 40-pt frame), so the frame alone bounds the fold.
    init(containerWidth: CGFloat, divisions: [CGRect], flatMaximumWidth: CGFloat = LibrarySidebarDefaults.phone.flatMaximumWidth) {
        let hinge = divisions.first { division in
            division.height > division.width && division.minX > 0 && division.maxX < containerWidth
        }
        self.init(containerWidth: containerWidth, hingeEdge: hinge?.minX, flatMaximumWidth: flatMaximumWidth)
    }

    init(
        containerWidth: CGFloat, hingeEdge: CGFloat?,
        flatMaximumWidth: CGFloat = LibrarySidebarDefaults.phone.flatMaximumWidth
    ) {
        self.containerWidth = containerWidth
        self.hingeEdge = hingeEdge
        self.flatMaximumWidth = flatMaximumWidth
    }

    var maximumExpandedWidth: CGFloat {
        let maximum = hingeEdge ?? min(flatMaximumWidth, containerWidth * Self.flatMaximumFraction)
        return max(Self.minimumExpandedWidth, maximum)
    }

    func width(isExpanded: Bool, expandedWidth: LibrarySidebarExpandedWidth) -> CGFloat {
        guard isExpanded else { return Self.railWidth }
        return switch expandedWidth {
        case .hinge: maximumExpandedWidth
        case .points(let points): clampedExpanded(points)
        }
    }

    /// The width a drag shows: it follows the finger between the rail and the maximum, and
    /// stretches less and less past either end.
    func dragWidth(_ proposed: CGFloat) -> CGFloat {
        let lower = Self.railWidth
        let upper = maximumExpandedWidth
        if proposed < lower { return lower - Self.rubberBand(lower - proposed) }
        if proposed > upper { return upper + Self.rubberBand(proposed - upper) }
        return proposed
    }

    /// Settles a released drag that started from `current`. A drag that barely traveled changes
    /// nothing. A release at the maximum keeps a hinge choice, so the column returns to the hinge
    /// after the next fold instead of staying at the flat maximum.
    func outcome(predictedWidth: CGFloat, travel: CGFloat, current: Outcome) -> Outcome {
        guard abs(travel) > Self.noChangeTravel else { return current }
        let settled = outcome(predictedWidth: predictedWidth)
        if current == .expanded(.hinge), settled == .expanded(.points(maximumExpandedWidth)) { return current }
        return settled
    }

    /// Settles a released drag from the width its velocity predicts.
    func outcome(predictedWidth: CGFloat) -> Outcome {
        if predictedWidth < Self.railSnapThreshold { return .rail }
        if let hingeEdge, predictedWidth >= hingeEdge - Self.hingeDetentDistance { return .expanded(.hinge) }
        return .expanded(.points(clampedExpanded(predictedWidth)))
    }

    /// How visible names are at a width: hidden on the rail, fully shown from the minimum expanded width.
    static func nameOpacity(at width: CGFloat) -> Double {
        let progress = (width - railWidth) / (minimumExpandedWidth - railWidth)
        return Double(min(max(progress, 0), 1))
    }

    private func clampedExpanded(_ width: CGFloat) -> CGFloat {
        min(max(width, Self.minimumExpandedWidth), maximumExpandedWidth)
    }

    private static func rubberBand(_ overshoot: CGFloat) -> CGFloat {
        rubberBandReach * (1 - 1 / (overshoot * 0.55 / rubberBandReach + 1))
    }
}
