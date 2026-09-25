import SwiftUI
import UIKit

enum ListPagePanDirection: Equatable {
    case left, right

    func clamped(_ translation: CGSize) -> CGSize {
        CGSize(
            width: self == .right ? max(0, translation.width) : min(0, translation.width),
            height: translation.height
        )
    }
}

struct ListPagePanObserver: UIViewRepresentable {
    let canBegin: (ListPagePanDirection) -> Bool
    let onPan: (ListPagePanDirection, CGSize, CGSize?, UIGestureRecognizer.State) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(canBegin: canBegin, onPan: onPan) }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        context.coordinator.attachmentView = view
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.canBegin = canBegin
        context.coordinator.onPan = onPan
    }

    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    final class AttachmentView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canBegin: (ListPagePanDirection) -> Bool
        var onPan: (ListPagePanDirection, CGSize, CGSize?, UIGestureRecognizer.State) -> Void
        weak var attachmentView: UIView?
        private weak var attachedWindow: UIWindow?
        private var recognizer: UIPanGestureRecognizer?
        private var direction: ListPagePanDirection?
        private var becameVertical = false
        private var presentationInterrupted = false

        init(
            canBegin: @escaping (ListPagePanDirection) -> Bool,
            onPan: @escaping (ListPagePanDirection, CGSize, CGSize?, UIGestureRecognizer.State) -> Void
        ) {
            self.canBegin = canBegin
            self.onPan = onPan
        }

        func attach(to window: UIWindow?) {
            guard attachedWindow !== window else { return }
            if let recognizer { attachedWindow?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            attachedWindow = window
            guard let window else { return }
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.cancelsTouchesInView = true
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
            guard let window = recognizer.view as? UIWindow else { return }
            let translation = recognizer.translation(in: window)
            let velocity = recognizer.velocity(in: window)
            if recognizer.state == .began {
                becameVertical = false
                presentationInterrupted = false
            }
            if abs(translation.y) > max(30, abs(translation.x) * 1.2) {
                becameVertical = true
            }
            if window.rootViewController?.presentedViewController != nil {
                presentationInterrupted = true
            }
            guard let direction else { return }
            let projected = CGSize(
                width: translation.x + velocity.x * 0.12,
                height: translation.y + velocity.y * 0.12
            )
            onPan(
                direction,
                CGSize(width: translation.x, height: translation.y),
                projected,
                becameVertical || presentationInterrupted ? .cancelled : recognizer.state
            )
            if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                becameVertical = false
                presentationInterrupted = false
                self.direction = nil
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            direction = nil
            guard let recognizer = gestureRecognizer as? UIPanGestureRecognizer,
                  let window = attachedWindow,
                  let direction = availableDirection(for: recognizer) else { return false }
            let translation = recognizer.translation(in: window)
            let velocity = recognizer.velocity(in: window)
            // A physical device can report zero translation at shouldBegin.
            let initialMovement = velocity == .zero ? translation : velocity
            guard abs(initialMovement.x) > abs(initialMovement.y) else { return false }
            self.direction = direction
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        private func availableDirection(for recognizer: UIPanGestureRecognizer) -> ListPagePanDirection? {
            guard let window = attachedWindow, let attachmentView,
                  window.rootViewController?.presentedViewController == nil else { return nil }
            let translation = recognizer.translation(in: window)
            let velocity = recognizer.velocity(in: window)
            let location = recognizer.location(in: window)
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            let contentFrame = attachmentView.convert(attachmentView.bounds, to: window)
            guard contentFrame.contains(start) else { return nil }
            let initialMovement = velocity == .zero ? translation : velocity
            let direction: ListPagePanDirection = initialMovement.x > 0 ? .right : .left
            if canBegin(direction) { return direction }
            return nil
        }

    }
}
