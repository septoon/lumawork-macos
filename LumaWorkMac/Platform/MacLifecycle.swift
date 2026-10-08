import AppKit
import EngineerCore

@MainActor
final class MacLifecycle {
    private let coordinator: EngineerApplicationCoordinator
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var wakeTask: Task<Void, Never>?
    private var wakeGeneration: UInt64 = 0

    init(coordinator: EngineerApplicationCoordinator) {
        self.coordinator = coordinator
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { [weak self] in
            self?.wakeGeneration &+= 1
            self?.wakeTask?.cancel()
            self?.wakeTask = nil
            self?.coordinator.lockProtectedContent()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in
            self?.resume()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.coordinator.lockProtectedContent()
        }
        observe(NotificationCenter.default, NSApplication.didResignActiveNotification) { [weak self] in
            self?.coordinator.lockProtectedContent()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, observer))
    }

    private func resume() {
        guard wakeTask == nil else { return }
        let generation = wakeGeneration
        wakeTask = Task { [weak self] in
            guard let self else { return }
            await coordinator.resumeAfterWake()
            if generation == wakeGeneration { wakeTask = nil }
        }
    }

    deinit {
        wakeTask?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}
