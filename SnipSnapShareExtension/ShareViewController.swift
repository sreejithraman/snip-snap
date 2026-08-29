import SwiftUI
@preconcurrency import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let extensionContext,
            let model = ShareExtensionModel(extensionContext: extensionContext)
        else {
            showUnavailable()
            return
        }
        let host = UIHostingController(rootView: ShareExtensionView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func showUnavailable() {
        let unavailable = ContentUnavailableView(
            "Shared Storage Unavailable",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("This build cannot access Snip Snap’s shared container.")
        )
        let host = UIHostingController(rootView: unavailable)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}
