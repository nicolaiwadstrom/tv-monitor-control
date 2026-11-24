import AppKit

// Single instance: if the app is already running (e.g. under the LaunchAgent), ask it to show
// its settings window and exit with status 0 (which the agent does not restart).
if let bundleID = Bundle.main.bundleIdentifier {
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != me }
    if !others.isEmpty {
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != BackgroundService.label {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("dev.local.TVMonitorControl.openSettings"),
                object: nil, userInfo: nil, deliverImmediately: true)
        }
        exit(0)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
