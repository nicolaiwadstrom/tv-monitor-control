import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let openSettingsNotification = Notification.Name("dev.local.LGTVControl.openSettings")

    private let store = ConfigStore()
    private lazy var controller = TVController(store: store)
    private lazy var volumeKeys = VolumeKeyService(store: store, volume: controller.volume)
    private var statusItem: NSStatusItem!
    private var monitor: PowerMonitor?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tv", accessibilityDescription: "LG TV Control")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor = PowerMonitor(
            onOff: { [weak self] in self?.controller.screensChanged(on: false) },
            onOn: { [weak self] in self?.controller.screensChanged(on: true) }
        )
        volumeKeys.start()

        // A second launch (Finder, Spotlight) pings us instead of starting another copy.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(openSettingsFromNotification(_:)),
            name: Self.openSettingsNotification, object: nil)

        if store.tvs.isEmpty { openSettings() }
    }

    // The app lives in the menu bar; closing the settings window never quits it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    // MARK: Menus

    /// An accessory app has no menu bar, but the key equivalents for copy/paste/close
    /// in the settings window's text fields still need a main menu.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if store.tvs.isEmpty {
            menu.addItem(withTitle: "No TVs configured", action: nil, keyEquivalent: "").isEnabled = false
        }
        for tv in store.tvs {
            let status = controller.status(tv.id)
            let title = tv.enabled ? tv.name : "\(tv.name) (disabled)"
            let item = menu.addItem(withTitle: status.isEmpty ? title : "\(title) — \(status)", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        if volumeKeys.needsPermission {
            menu.addItem(.separator())
            menu.addItem(item("Volume keys need Accessibility access…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Turn all TVs on", #selector(allOn)))
        menu.addItem(item("Turn all TVs off", #selector(allOff)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        let service = item("Run as background service (auto-restart)", #selector(toggleService))
        service.state = BackgroundService.isEnabled ? .on : .off
        menu.addItem(service)
        menu.addItem(.separator())
        menu.addItem(item("About TV Control", #selector(showAbout)))
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    // MARK: Actions

    @objc private func allOn() { controller.setAll(on: true) }
    @objc private func allOff() { controller.setAll(on: false) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        a.messageText = "TV Control for MacOS v\(version)"
        a.informativeText = "(C) Copyright Nicolai Wadstrom 2026."
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleService() {
        guard Bundle.main.bundleIdentifier != nil else {
            alert("Run the packaged LGTVControl.app (./build_app.sh) to use the background service.")
            return
        }
        do {
            if BackgroundService.isEnabled {
                alert("The background service will be removed and the app will quit. Open it again if you still want it running.")
                try BackgroundService.disable()
            } else {
                try BackgroundService.enable()
                if BackgroundService.status == .requiresApproval {
                    alert("Allow “LG TV Control” under System Settings → General → Login Items, then choose this menu item again.")
                }
            }
        } catch {
            alert("Could not change the background service: \(error.localizedDescription)")
        }
    }

    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "LG TV Control"
        a.informativeText = text
        a.runModal()
    }

    @objc private func openSettingsFromNotification(_ note: Notification) { openSettings() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: store, controller: controller))
            let window = NSWindow(contentViewController: hosting)
            window.title = "LG TV Control"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
