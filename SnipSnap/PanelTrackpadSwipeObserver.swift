import AppKit
import SwiftUI

enum PanelSwipeDirection: Equatable {
    case previous
    case next
}

struct PanelTrackpadSwipeState {
    private(set) var isActive = false
    private var horizontalDistance: CGFloat = 0
    private var verticalDistance: CGFloat = 0
    private var hasResolved = false

    mutating func reset() {
        isActive = false
        horizontalDistance = 0
        verticalDistance = 0
        hasResolved = false
    }

    mutating func update(
        horizontal: CGFloat,
        vertical: CGFloat,
        phase: NSEvent.Phase
    ) -> PanelSwipeDirection? {
        if phase == .mayBegin {
            reset()
            return nil
        }
        if phase == .began {
            reset()
            isActive = true
        }
        if phase == .ended || phase == .cancelled {
            reset()
            return nil
        }
        guard isActive, !hasResolved else { return nil }

        horizontalDistance += horizontal
        verticalDistance += vertical
        if abs(verticalDistance) > max(18, abs(horizontalDistance) * 1.25) {
            hasResolved = true
            return nil
        }
        guard abs(horizontalDistance) >= 72,
              abs(horizontalDistance) > abs(verticalDistance) * 1.4 else { return nil }
        hasResolved = true
        // AppKit has already applied the user's scroll direction preference.
        return horizontalDistance > 0 ? .previous : .next
    }
}

enum PanelTrackpadSwipeRegion {
    static func contains(
        _ point: NSPoint,
        in bounds: NSRect,
        excludingBottom height: CGFloat
    ) -> Bool {
        bounds.contains(point) && point.y >= bounds.minY + height
    }
}

/// Observes fluid swipes in the panel without taking vertical scrolling from its rows.
struct PanelTrackpadSwipeObserver: NSViewRepresentable {
    let excludedBottomHeight: CGFloat
    let canNavigate: () -> Bool
    let navigate: (PanelSwipeDirection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            excludedBottomHeight: excludedBottomHeight,
            canNavigate: canNavigate,
            navigate: navigate
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.observedView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.excludedBottomHeight = excludedBottomHeight
        context.coordinator.canNavigate = canNavigate
        context.coordinator.navigate = navigate
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var observedView: NSView?
        var excludedBottomHeight: CGFloat
        var canNavigate: () -> Bool
        var navigate: (PanelSwipeDirection) -> Void
        private var monitor: Any?
        private var swipe = PanelTrackpadSwipeState()
        private var isOverHorizontalScroller = false

        init(
            excludedBottomHeight: CGFloat,
            canNavigate: @escaping () -> Bool,
            navigate: @escaping (PanelSwipeDirection) -> Void
        ) {
            self.excludedBottomHeight = excludedBottomHeight
            self.canNavigate = canNavigate
            self.navigate = navigate
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.observe(event)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            swipe.reset()
            isOverHorizontalScroller = false
        }

        private func observe(_ event: NSEvent) {
            guard let view = observedView,
                  let window = view.window,
                  event.window === window,
                  window.attachedSheet == nil,
                  NSApp.modalWindow == nil,
                  PanelTrackpadSwipeRegion.contains(
                    view.convert(event.locationInWindow, from: nil),
                    in: view.bounds,
                    excludingBottom: excludedBottomHeight
                  ),
                  canNavigate() else {
                swipe.reset()
                isOverHorizontalScroller = false
                return
            }

            guard event.hasPreciseScrollingDeltas,
                  event.momentumPhase.isEmpty,
                  !event.phase.isEmpty else { return }
            if event.phase == .began {
                isOverHorizontalScroller = isOverHorizontalScrollView(event, in: window)
            }
            if event.phase == .ended || event.phase == .cancelled {
                isOverHorizontalScroller = false
            }
            guard !isOverHorizontalScroller else { return }
            if let direction = swipe.update(
                horizontal: event.scrollingDeltaX,
                vertical: event.scrollingDeltaY,
                phase: event.phase
            ) {
                navigate(direction)
            }
        }

        private func isOverHorizontalScrollView(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard let contentView = window.contentView else { return false }
            var view: NSView? = contentView.hitTest(
                contentView.convert(event.locationInWindow, from: nil)
            )
            while let current = view {
                if let scrollView = current as? NSScrollView,
                   let documentView = scrollView.documentView,
                   (scrollView.hasHorizontalScroller
                        || scrollView.horizontalScrollElasticity == .allowed),
                   documentView.bounds.width > scrollView.contentView.bounds.width + 8 {
                    return true
                }
                view = current.superview
            }
            return false
        }
    }
}
