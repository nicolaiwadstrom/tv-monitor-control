import AppKit
import ServiceManagement

/// Registers a per-user LaunchAgent (shipped inside the app bundle) that starts the app at login
/// and restarts it if it crashes. A normal Quit (exit code 0) is not restarted.
enum BackgroundService {
    static let label = "dev.local.TVMonitorControl.agent"
    static let plistName = "dev.local.TVMonitorControl.agent.plist"

    static var service: SMAppService { .agent(plistName: plistName) }
    static var status: SMAppService.Status { service.status }
    static var isEnabled: Bool { status == .enabled }

    /// Registers the agent. On success the app relaunches itself under launchd supervision.
    static func enable() throws {
        try service.register()
        guard service.status == .enabled else {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        // Registering starts the agent, but it exits because this instance is running.
        // Kick it again once we've quit so the running app is the supervised one.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1.5; /bin/launchctl kickstart gui/\(getuid())/\(label)"]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Unregistering stops the supervised instance, so the app quits.
    static func disable() throws {
        try service.unregister()
    }
}
