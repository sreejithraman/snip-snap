import SwiftUI
import UIKit

struct CollectionScreenPresentation<TrailingControls: View>: ViewModifier {
    let title: String
    var titleColor: Color = .primary
    var showsControls = true
    var recedesControls = false
    let trailingControls: TrailingControls

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(title.isEmpty ? .inline : .large)
            .background {
                RoundedNavigationTitle(color: UIColor(titleColor))
                    .frame(width: 0, height: 0)
            }
            .toolbar {
                if showsControls {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        trailingControls
                            .tint(recedesControls ? Color.secondary : SnipSnapTheme.controlTint)
                    }
                    .sharedBackgroundVisibility(recedesControls ? .hidden : .automatic)
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
