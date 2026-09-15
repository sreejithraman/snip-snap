import AppKit
import Carbon.HIToolbox

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
    static let eventMask: NSEvent.EventTypeMask = [
        .flagsChanged,
        .keyDown,
        .keyUp,
    ]

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

    mutating func receive(_ event: NSEvent) -> DoubleShiftGesture? {
        guard event.type == .flagsChanged,
              event.keyCode == UInt16(kVK_Shift) || event.keyCode == UInt16(kVK_RightShift) else {
            cancel()
            return nil
        }
        let side: ShiftSide = event.keyCode == UInt16(kVK_Shift) ? .left : .right
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let otherFlags = flags.subtracting(.shift).intersection([.command, .control, .option])
        let modifier: DoubleShiftModifier
        if otherFlags.isEmpty {
            modifier = .none
        } else if otherFlags == .command {
            modifier = .command
        } else {
            cancel()
            return nil
        }
        let gesture = DoubleShiftGesture(side: side, modifier: modifier)
        return shiftChanged(
            gesture: gesture,
            isDown: flags.contains(.shift),
            timestamp: event.timestamp
        ) ? gesture : nil
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
