import AppKit
import SwiftUI

enum PanelSwipeDirection: Equatable {
    case previous
    case next
}

enum PanelSwipeDecision: Equatable {
    case pass
    case consume
    case navigate(PanelSwipeDirection)
}

struct PanelTrackpadSwipeState {
    private enum Axis {
        case undecided
        case horizontal
        case vertical
    }

    private(set) var isActive = false
    private var horizontalDistance: CGFloat = 0
    private var verticalDistance: CGFloat = 0
    private var hasNavigated = false
    private var axis: Axis = .undecided
    private var horizontalDirection: CGFloat = 0

    func keepsHorizontalAdmission(for phase: NSEvent.Phase) -> Bool {
        axis == .horizontal && phase != .began && phase != .mayBegin
    }

    mutating func reset() {
        isActive = false
        horizontalDistance = 0
        verticalDistance = 0
        hasNavigated = false
        axis = .undecided
        horizontalDirection = 0
    }

    mutating func update(
        horizontal: CGFloat,
        vertical: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase = []
    ) -> PanelSwipeDecision {
        if phase == .mayBegin {
            reset()
            return .pass
        }
        if !momentumPhase.isEmpty {
            let decision: PanelSwipeDecision = axis == .horizontal ? .consume : .pass
            if momentumPhase == .ended || momentumPhase == .cancelled { reset() }
            return decision
        }
        if phase == .began {
            reset()
            isActive = true
        }
        if phase == .ended || phase == .cancelled {
            let decision: PanelSwipeDecision = axis == .horizontal ? .consume : .pass
            if phase == .cancelled { reset() } else { isActive = false }
            return decision
        }
        guard isActive else { return .pass }

        if axis != .horizontal || horizontal * horizontalDirection >= 0 {
            horizontalDistance += horizontal
        }
        verticalDistance += vertical
        if axis == .undecided {
            guard horizontalDistance != 0 || verticalDistance != 0 else { return .pass }
            // Do not commit an axis from a couple of noisy opening deltas.
            guard max(abs(horizontalDistance), abs(verticalDistance)) >= 4 else { return .consume }
            axis = abs(horizontalDistance) > abs(verticalDistance) ? .horizontal : .vertical
            if axis == .horizontal { horizontalDirection = horizontalDistance > 0 ? 1 : -1 }
        }
        if axis == .vertical {
            return .pass
        }
        guard !hasNavigated,
              axis == .horizontal,
              abs(horizontalDistance) >= 72 else {
            return .consume
        }
        hasNavigated = true
        // AppKit has already applied the user's scroll direction preference.
        return .navigate(horizontalDistance > 0 ? .previous : .next)
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

/// Routes horizontal trackpad swipes to tabs while preserving vertical list scrolling.
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
                guard let self else { return event }
                return self.observe(event)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            swipe.reset()
            isOverHorizontalScroller = false
        }

        private func observe(_ event: NSEvent) -> NSEvent? {
            guard let view = observedView,
                  let window = view.window,
                  event.window === window,
                  window.attachedSheet == nil,
                  NSApp.modalWindow == nil else {
                swipe.reset()
                isOverHorizontalScroller = false
                return event
            }

            guard event.hasPreciseScrollingDeltas,
                  (!event.phase.isEmpty || !event.momentumPhase.isEmpty) else { return event }
            if !swipe.keepsHorizontalAdmission(for: event.phase),
               !(PanelTrackpadSwipeRegion.contains(
                    view.convert(event.locationInWindow, from: nil),
                    in: view.bounds,
                    excludingBottom: excludedBottomHeight
                  ) && canNavigate()) {
                swipe.reset()
                isOverHorizontalScroller = false
                return event
            }
            if event.phase == .began {
                isOverHorizontalScroller = isOverHorizontalScrollView(event, in: window)
                if isOverHorizontalScroller { swipe.reset() }
            }
            if event.phase == .ended || event.phase == .cancelled
                || event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                isOverHorizontalScroller = false
            }
            guard !isOverHorizontalScroller else { return event }
            switch swipe.update(
                horizontal: event.scrollingDeltaX,
                vertical: event.scrollingDeltaY,
                phase: event.phase,
                momentumPhase: event.momentumPhase
            ) {
            case .pass:
                return event
            case .consume:
                return nil
            case .navigate(let direction):
                if canNavigate() { navigate(direction) }
                return nil
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
