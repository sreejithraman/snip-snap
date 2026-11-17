import SwiftUI
import UIKit

private struct ShowsPageToolbarKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var showsPageToolbar: Bool {
        get { self[ShowsPageToolbarKey.self] }
        set { self[ShowsPageToolbarKey.self] = newValue }
    }
}

struct CollectionScreenPresentation<TrailingControls: View, LibraryActions: View>: ViewModifier {
    @Environment(\.showsPageToolbar) private var showsPageToolbar
    @Environment(\.prefersSideButtons) private var prefersSideButtons
    @ScaledMetric(relativeTo: .body) private var controlLength: CGFloat = 32
    let title: String
    var titleColor: Color = .primary
    var showsControls = true
    var recedesControls = false
    let trailingControls: TrailingControls
    let libraryActions: LibraryActions?

    private var controlTint: Color { recedesControls ? Color.secondary : SnipSnapTheme.controlTint }
    private var sharedBackground: Visibility { recedesControls || !showsPageToolbar ? .hidden : .automatic }

    // UIKit adopts menus as bar buttons, so hidden pages need an empty slot, not a hidden menu.
    @ViewBuilder
    private func controls<Controls: View>(_ controls: Controls) -> some View {
        if showsPageToolbar {
            controls.tint(controlTint)
        } else {
            Color.clear
                .frame(width: controlLength, height: controlLength)
                .accessibilityHidden(true)
        }
    }

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(title.isEmpty ? .inline : .large)
            .background {
                AppNavigationTitle(color: UIColor(titleColor))
                    .frame(width: 0, height: 0)
            }
            .toolbar {
                if showsControls {
                    if prefersSideButtons {
                        // Fixed spacers keep each control in its own circle in the trailing column.
                        ToolbarItem(placement: .topBarTrailing) {
                            controls(trailingControls)
                        }
                        .sharedBackgroundVisibility(sharedBackground)
                        .sideButton()
                        if let libraryActions {
                            ToolbarSpacer(.fixed, placement: .topBarTrailing)
                                .sideButton()
                            ToolbarItem(placement: .topBarTrailing) {
                                controls(libraryActions)
                            }
                            .sharedBackgroundVisibility(sharedBackground)
                            .sideButton()
                        }
                    } else {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            controls(trailingControls)
                            if let libraryActions {
                                controls(libraryActions)
                            }
                        }
                        .sharedBackgroundVisibility(sharedBackground)
                    }
                }
            }
    }
}

/// Style this screen's native title while keeping its scroll and accessibility behavior.
private struct AppNavigationTitle: UIViewControllerRepresentable {
    let color: UIColor

    func makeUIViewController(context: Context) -> TitleController {
        TitleController()
    }

    func updateUIViewController(_ controller: TitleController, context: Context) {
        controller.titleColor = color
        controller.applyAppearance()
    }

    final class TitleController: UIViewController {
        var titleColor: UIColor = .label

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyAppearance()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyAppearance()
        }

        func applyAppearance() {
            guard let navigationController,
                  let item = navigationController.topViewController?.navigationItem else { return }
            let bar = navigationController.navigationBar
            // iPad drops the leading minimum margin for a column that starts inside the window, as
            // the page card beside the rail does, which would pin the large title to the card's edge.
            var margins = navigationController.view.directionalLayoutMargins
            if traitCollection.userInterfaceIdiom == .pad, margins.leading < margins.trailing {
                margins.leading = margins.trailing
                navigationController.view.directionalLayoutMargins = margins
            }
            func styled(_ source: UINavigationBarAppearance) -> UINavigationBarAppearance {
                let appearance = source.copy() as! UINavigationBarAppearance
                appearance.titleTextAttributes[.font] = AppTypography.preferredFont(.headline, compatibleWith: traitCollection)
                appearance.largeTitleTextAttributes[.font] = AppTypography.preferredFont(.largeTitle, weight: .bold, compatibleWith: traitCollection)
                appearance.titleTextAttributes[.foregroundColor] = titleColor
                appearance.largeTitleTextAttributes[.foregroundColor] = titleColor
                return appearance
            }
            item.standardAppearance = styled(bar.standardAppearance)
            item.scrollEdgeAppearance = styled(bar.scrollEdgeAppearance ?? bar.standardAppearance)
            item.compactAppearance = styled(bar.compactAppearance ?? bar.standardAppearance)
        }
    }
}
