import AppKit

/// Observes display and system sleep/wake. Display sleep covers the
/// "screen saver → turn display off" case; system sleep covers lid close / Apple menu → Sleep.
final class PowerMonitor {
    private var tokens: [NSObjectProtocol] = []

    init(onOff: @escaping @MainActor () -> Void, onOn: @escaping @MainActor () -> Void) {
        let nc = NSWorkspace.shared.notificationCenter
        let offEvents: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification,
        ]
        let onEvents: [Notification.Name] = [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
        ]
        for name in offEvents {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onOff() }
            })
        }
        for name in onEvents {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onOn() }
            })
        }
    }

    deinit {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
