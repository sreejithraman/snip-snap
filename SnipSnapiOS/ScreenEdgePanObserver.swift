import SwiftUI
import UIKit

struct ScreenEdgePanObserver: UIViewRepresentable {
    let canBegin: (UIRectEdge) -> Bool
    let onPan: (UIRectEdge, CGSize, CGSize?, UIGestureRecognizer.State) -> Void

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
        var canBegin: (UIRectEdge) -> Bool
        var onPan: (UIRectEdge, CGSize, CGSize?, UIGestureRecognizer.State) -> Void
        weak var attachmentView: UIView?
        private weak var attachedWindow: UIWindow?
        private var recognizer: UIPanGestureRecognizer?
        private var becameVertical = false
        private var presentationInterrupted = false

        init(
            canBegin: @escaping (UIRectEdge) -> Bool,
            onPan: @escaping (UIRectEdge, CGSize, CGSize?, UIGestureRecognizer.State) -> Void
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
            let startX = recognizer.location(in: window).x - translation.x
            let edge: UIRectEdge = startX < window.bounds.midX ? .left : .right
            let projected = CGSize(
                width: translation.x + velocity.x * 0.12,
                height: translation.y + velocity.y * 0.12
            )
            onPan(
                edge,
                CGSize(width: translation.x, height: translation.y),
                projected,
                becameVertical || presentationInterrupted ? .cancelled : recognizer.state
            )
            if recognizer.state == .ended || recognizer.state == .cancelled {
                becameVertical = false
                presentationInterrupted = false
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let recognizer = gestureRecognizer as? UIPanGestureRecognizer,
                  let window = attachedWindow,
                  let edge = availableEdge(for: recognizer) else { return false }
            let translation = recognizer.translation(in: window)
            guard abs(translation.x) > abs(translation.y) else { return false }
            return edge == .left ? translation.x > 0 : translation.x < 0
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard otherGestureRecognizer is UIPanGestureRecognizer,
                  let recognizer = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            return availableEdge(for: recognizer) != nil
        }

        private func availableEdge(for recognizer: UIPanGestureRecognizer) -> UIRectEdge? {
            guard let window = attachedWindow, let attachmentView,
                  window.rootViewController?.presentedViewController == nil else { return nil }
            let translation = recognizer.translation(in: window)
            let location = recognizer.location(in: window)
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            let contentFrame = attachmentView.convert(attachmentView.bounds, to: window)
            guard contentFrame.contains(start) else { return nil }
            if start.x <= contentFrame.minX + 24, canBegin(.left) { return .left }
            if start.x >= contentFrame.maxX - 24, canBegin(.right) { return .right }
            return nil
        }

    }
}
