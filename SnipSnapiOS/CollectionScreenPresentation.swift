import SwiftUI
import UIKit

private struct SuppliesPageToolbarKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var suppliesPageToolbar: Bool {
        get { self[SuppliesPageToolbarKey.self] }
        set { self[SuppliesPageToolbarKey.self] = newValue }
    }
}

struct CollectionScreenPresentation<TrailingControls: View, LibraryActions: View>: ViewModifier {
    @Environment(\.suppliesPageToolbar) private var suppliesPageToolbar
    @Environment(\.prefersSideButtons) private var prefersSideButtons
    let title: String
    var titleColor: Color = .primary
    var showsControls = true
    var recedesControls = false
    let trailingControls: TrailingControls
    /// Gets its own side button. Without side buttons the caller keeps it in `trailingControls`.
    let libraryActions: LibraryActions?

    private var controlTint: Color { recedesControls ? Color.secondary : SnipSnapTheme.controlTint }
    private var sharedBackground: Visibility { recedesControls ? .hidden : .automatic }

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(title.isEmpty ? .inline : .large)
            .background {
                RoundedNavigationTitle(color: UIColor(titleColor))
                    .frame(width: 0, height: 0)
            }
            .toolbar {
                if showsControls && suppliesPageToolbar {
                    if prefersSideButtons {
                        // Fixed spacers keep each control in its own circle in the trailing column.
                        ToolbarItem(placement: .topBarTrailing) {
                            trailingControls.tint(controlTint)
                        }
                        .sharedBackgroundVisibility(sharedBackground)
                        .sideButton()
                        if let libraryActions {
                            ToolbarSpacer(.fixed, placement: .topBarTrailing)
                                .sideButton()
                            ToolbarItem(placement: .topBarTrailing) {
                                libraryActions.tint(controlTint)
                            }
                            .sharedBackgroundVisibility(sharedBackground)
                            .sideButton()
                        }
                    } else {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            trailingControls.tint(controlTint)
                        }
                        .sharedBackgroundVisibility(sharedBackground)
                    }
                }
            }
    }
}

/// Style this screen's native title while keeping its scroll and accessibility behavior.
private struct RoundedNavigationTitle: UIViewControllerRepresentable {
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
            func styled(_ source: UINavigationBarAppearance) -> UINavigationBarAppearance {
                let appearance = source.copy() as! UINavigationBarAppearance
                appearance.titleTextAttributes[.font] = UIFont.rounded(size: 17, weight: .semibold)
                appearance.largeTitleTextAttributes[.font] = UIFont.rounded(size: 34, weight: .bold)
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
