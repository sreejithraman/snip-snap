import AppKit
import Carbon.HIToolbox

@MainActor
protocol GlobalHotKeyManaging: AnyObject {
    func register(configuration: GlobalShortcutConfiguration) throws
    func unregister()
}

@MainActor
final class GlobalHotKeyManager: GlobalHotKeyManaging {
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var doubleShiftRouter = DoubleShiftRouter(gestures: [])
    private var doubleShiftActions: [DoubleShiftGesture: GlobalHotKeyAction] = [:]
    private let handler: (GlobalHotKeyAction) -> Void

    init(handler: @escaping (GlobalHotKeyAction) -> Void) {
        self.handler = handler
    }

    func register(configuration: GlobalShortcutConfiguration) throws {
        do {
            try installEventHandler()
            for action in GlobalHotKeyAction.allCases {
                switch configuration.trigger(for: action) {
                case .doubleShift(let side):
                    doubleShiftActions[
                        DoubleShiftGesture(side: side, modifier: .none)
                    ] = action
                case .commandDoubleShift(let side):
                    doubleShiftActions[
                        DoubleShiftGesture(side: side, modifier: .command)
                    ] = action
                case .keyChord(let chord):
                    try register(chord: chord, action: action)
                }
            }
            if !doubleShiftActions.isEmpty {
                doubleShiftRouter = DoubleShiftRouter(gestures: doubleShiftActions.keys)
                installDoubleShiftMonitors()
            }
        } catch {
            unregister()
            throw error
        }
    }

    fileprivate func receive(_ action: GlobalHotKeyAction) {
        handler(action)
    }

    func unregister() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        doubleShiftActions = [:]
        doubleShiftRouter = DoubleShiftRouter(gestures: [])
    }

    private func installEventHandler() throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            snipSnapGlobalHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else {
            throw GlobalHotKeyError.eventHandler(status)
        }
    }

    private func register(chord: ShortcutKeyChord, action: GlobalHotKeyAction) throws {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(
            signature: OSType(0x53504F4C),
            id: action.rawValue
        )
        let status = RegisterEventHotKey(
            chord.keyCode,
            chord.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw GlobalHotKeyError.registration(status)
        }
        hotKeys.append(reference)
    }

    private func installDoubleShiftMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: DoubleShiftRouter.eventMask
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.receiveForDoubleShift(event)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: DoubleShiftRouter.eventMask
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.receiveForDoubleShift(event)
            }
        }
    }

    private func receiveForDoubleShift(_ event: NSEvent) {
        if let gesture = doubleShiftRouter.receive(event),
           let action = doubleShiftActions[gesture] {
            handler(action)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            unregister()
        }
    }
}

private func snipSnapGlobalHotKeyHandler(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr,
          let action = GlobalHotKeyAction(rawValue: identifier.id) else {
        return OSStatus(eventNotHandledErr)
    }
    let manager = Unmanaged<GlobalHotKeyManager>
        .fromOpaque(userData)
        .takeUnretainedValue()
    Task { @MainActor in
        manager.receive(action)
    }
    return noErr
}
