import AppKit
import Carbon.HIToolbox

@MainActor
protocol GlobalHotKeyManaging: AnyObject {
    func register(configuration: GlobalShortcutConfiguration) throws
    func unregister()
}

@MainActor
final class GlobalHotKeyManager: GlobalHotKeyManaging {
    private enum Registration {
        case unregistered
        case installing(GlobalHotKeyResources)
        case registered(GlobalHotKeyResources)
        case rolledBack
    }

    private var registration = Registration.unregistered
    private let handler: (GlobalHotKeyAction) -> Void

    init(handler: @escaping (GlobalHotKeyAction) -> Void) {
        self.handler = handler
    }

    func register(configuration: GlobalShortcutConfiguration) throws {
        unregister()
        let resources = GlobalHotKeyResources()
        registration = .installing(resources)
        do {
            try resources.installEventHandler(for: self)
            for action in GlobalHotKeyAction.allCases {
                try resources.add(configuration.trigger(for: action), for: action)
            }
            resources.installDoubleShiftMonitors(for: self)
            registration = .registered(resources)
        } catch {
            resources.release()
            registration = .rolledBack
            throw error
        }
    }

    fileprivate func receive(_ action: GlobalHotKeyAction) {
        guard case .registered = registration, !ShortcutRecordingState.isActive else { return }
        handler(action)
    }

    func unregister() {
        switch registration {
        case .installing(let resources), .registered(let resources):
            resources.release()
        case .unregistered, .rolledBack:
            break
        }
        registration = .unregistered
    }

    func receiveForDoubleShift(_ event: NSEvent) {
        guard case .registered(let resources) = registration else { return }
        guard !ShortcutRecordingState.isActive else {
            resources.cancelDoubleShift()
            return
        }
        if let action = resources.doubleShiftAction(for: event) {
            handler(action)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            unregister()
        }
    }
}

@MainActor
private final class GlobalHotKeyResources {
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var doubleShiftActions: [DoubleShiftGesture: GlobalHotKeyAction] = [:]
    private var doubleShiftRouter = DoubleShiftRouter(gestures: [])

    func installEventHandler(for manager: GlobalHotKeyManager) throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            snipSnapGlobalHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(manager).toOpaque(),
            &eventHandler
        )
        guard status == noErr else {
            throw GlobalHotKeyError.eventHandler(status)
        }
    }

    func add(_ trigger: ShortcutTrigger, for action: GlobalHotKeyAction) throws {
        switch trigger {
        case .doubleShift(let side):
            doubleShiftActions[DoubleShiftGesture(side: side, modifier: .none)] = action
        case .commandDoubleShift(let side):
            doubleShiftActions[DoubleShiftGesture(side: side, modifier: .command)] = action
        case .keyChord(let chord):
            try register(chord: chord, action: action)
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

    func installDoubleShiftMonitors(for manager: GlobalHotKeyManager) {
        guard !doubleShiftActions.isEmpty else { return }
        doubleShiftRouter = DoubleShiftRouter(gestures: doubleShiftActions.keys)
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: DoubleShiftRouter.eventMask
        ) { [weak manager] event in
            MainActor.assumeIsolated {
                manager?.receiveForDoubleShift(event)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: DoubleShiftRouter.eventMask
        ) { [weak manager] event in
            MainActor.assumeIsolated {
                manager?.receiveForDoubleShift(event)
            }
        }
    }

    func doubleShiftAction(for event: NSEvent) -> GlobalHotKeyAction? {
        doubleShiftRouter.receive(event).flatMap { doubleShiftActions[$0] }
    }

    func cancelDoubleShift() {
        doubleShiftRouter.cancel()
    }

    func release() {
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
    MainActor.assumeIsolated {
        manager.receive(action)
    }
    return noErr
}
