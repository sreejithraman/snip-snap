import SnipSnapCore
import UIKit

/// Opens App Group file locks only while the app cannot be suspended.
///
/// A launch may be a background launch, so the gate starts closed until UIKit reports the
/// app active. Entering the background closes it inside UIKit's own callback, where a
/// background task is guaranteed to start, and ends that task once held locks are released.
@MainActor
final class IOSSharedContainerLockLifecycle {
    private let gate: SharedContainerLockGate
    private let beginBackgroundTask: @MainActor (
        _ expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier
    private let endBackgroundTask: @MainActor (UIBackgroundTaskIdentifier) -> Void
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(
        gate: SharedContainerLockGate = .process,
        notificationCenter: NotificationCenter = .default,
        beginBackgroundTask: @escaping @MainActor (
            _ expirationHandler: @escaping @MainActor @Sendable () -> Void
        ) -> UIBackgroundTaskIdentifier = {
            UIApplication.shared.beginBackgroundTask(
                withName: "Release App Group locks", expirationHandler: $0
            )
        },
        endBackgroundTask: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = {
            UIApplication.shared.endBackgroundTask($0)
        }
    ) {
        self.gate = gate
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
        self.notificationCenter = notificationCenter
        gate.close()
        let open: @Sendable (Notification) -> Void = { _ in gate.open() }
        observers = [
            notificationCenter.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main,
                using: open
            ),
            notificationCenter.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main,
                using: open
            ),
            notificationCenter.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeForBackground() }
            },
        ]
    }

    isolated deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    private func closeForBackground() {
        let task = BackgroundTask(end: endBackgroundTask)
        task.identifier = beginBackgroundTask { task.end() }
        gate.close { Task { @MainActor in task.end() } }
    }

    @MainActor
    private final class BackgroundTask {
        var identifier = UIBackgroundTaskIdentifier.invalid
        private let endTask: @MainActor (UIBackgroundTaskIdentifier) -> Void

        init(end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void) {
            endTask = end
        }

        func end() {
            guard identifier != .invalid else { return }
            endTask(identifier)
            identifier = .invalid
        }
    }
}
