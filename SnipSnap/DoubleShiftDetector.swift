import Foundation

enum DoubleShiftModifier: Hashable, Sendable {
    case none
    case command
}

struct DoubleShiftGesture: Hashable, Sendable {
    let side: ShiftSide
    let modifier: DoubleShiftModifier
}

struct DoubleShiftDetector: Sendable {
    private enum Phase: Sendable {
        case idle
        case firstDown(TimeInterval)
        case firstUp(TimeInterval)
    }

    private var phase: Phase = .idle
    let maximumTapDuration: TimeInterval
    let maximumGap: TimeInterval

    init(maximumTapDuration: TimeInterval = 0.25, maximumGap: TimeInterval = 0.35) {
        self.maximumTapDuration = maximumTapDuration
        self.maximumGap = maximumGap
    }

    mutating func shiftChanged(
        isDown: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        if isDown {
            if case .firstUp(let firstUpTime) = phase,
               timestamp - firstUpTime <= maximumGap {
                phase = .idle
                return true
            }
            phase = .firstDown(timestamp)
            return false
        }

        guard case .firstDown(let downTime) = phase,
              timestamp - downTime <= maximumTapDuration else {
            phase = .idle
            return false
        }
        phase = .firstUp(timestamp)
        return false
    }

    mutating func cancel() {
        phase = .idle
    }
}

struct DoubleShiftRouter: Sendable {
    private var detectors: [DoubleShiftGesture: DoubleShiftDetector]

    init(gestures: some Sequence<DoubleShiftGesture>) {
        detectors = Dictionary(
            uniqueKeysWithValues: gestures.map { ($0, DoubleShiftDetector()) }
        )
    }

    mutating func shiftChanged(
        gesture: DoubleShiftGesture,
        isDown: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        cancel(except: gesture)
        guard var detector = detectors[gesture] else { return false }
        let shouldFire = detector.shiftChanged(
            isDown: isDown,
            timestamp: timestamp
        )
        detectors[gesture] = detector
        return shouldFire
    }

    mutating func cancel() {
        cancel(except: nil)
    }

    private mutating func cancel(except keptGesture: DoubleShiftGesture?) {
        for gesture in Array(detectors.keys) where gesture != keptGesture {
            guard var detector = detectors[gesture] else { continue }
            detector.cancel()
            detectors[gesture] = detector
        }
    }
}
