import Foundation
import os

private let log = Logger(subsystem: "dev.local.LGTVControl", category: "tv")

@MainActor
final class TVController: ObservableObject {
    @Published private(set) var statuses: [UUID: String] = [:]

    private let store: ConfigStore
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var desiredOn: Bool?

    /// Volume commands are suspended while the screens are meant to be off.
    lazy var volume = VolumeController(store: store) { [weak self] in
        MainActor.assumeIsolated { self?.desiredOn != false }
    }

    init(store: ConfigStore) {
        self.store = store
    }

    // MARK: Entry points

    /// Called by the power monitor. Ignores repeated events for the same state.
    func screensChanged(on: Bool) {
        guard desiredOn != on else { return }
        setAll(on: on)
    }

    /// Manual trigger (menu / test buttons); always acts.
    func setAll(on: Bool) {
        desiredOn = on
        if !on { volume.disconnectAll() }
        for tv in store.tvs where tv.enabled { set(tv.id, on: on) }
    }

    func set(_ id: UUID, on: Bool) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            if on { await self.turnOn(id) } else { await self.turnOff(id) }
        }
    }

    func status(_ id: UUID) -> String { statuses[id] ?? "" }

    // MARK: Pairing / discovery

    /// Connects (showing the pairing prompt on the TV if needed), stores the key,
    /// fills in the MAC and the list of inputs.
    func pair(_ id: UUID) async {
        guard let tv = store.tv(id) else { return }
        setStatus(id, "Connecting… accept the prompt on the TV if it appears")
        let client = WebOSClient(host: tv.ip, clientKey: tv.clientKey)
        defer { client.close() }
        do {
            try await client.connect(pairingTimeout: 60)
            store.update(id) { $0.clientKey = client.clientKey }
            if let reply = try? await client.request("ssap://tv/getExternalInputList"),
               let devices = reply["devices"] as? [[String: Any]] {
                let ids = devices.compactMap { $0["id"] as? String }
                store.update(id) { $0.knownInputs = ids }
            }
            if store.tv(id)?.mac.isEmpty == true, let mac = await WakeOnLAN.lookupMAC(ip: tv.ip) {
                store.update(id) { $0.mac = mac }
            }
            setStatus(id, "Paired")
        } catch {
            setStatus(id, "Pairing failed: \(error.localizedDescription)")
        }
    }

    func detectMAC(_ id: UUID) async {
        guard let tv = store.tv(id) else { return }
        setStatus(id, "Looking up MAC address…")
        if let mac = await WakeOnLAN.lookupMAC(ip: tv.ip) {
            store.update(id) { $0.mac = mac }
            setStatus(id, "MAC detected: \(mac)")
        } else {
            setStatus(id, "Could not find MAC (is the TV on and on the same subnet?)")
        }
    }

    // MARK: Operations

    private func turnOff(_ id: UUID) async {
        guard let tv = store.tv(id) else { return }
        setStatus(id, "Turning off…")
        let client = WebOSClient(host: tv.ip, clientKey: tv.clientKey)
        defer { client.close() }
        do {
            try await client.connect(pairingTimeout: 5)
            persistKey(id, client)
            switch tv.mode {
            case .powerOff:
                try await client.request("ssap://system/turnOff")
            case .screenOff:
                do {
                    try await client.request("ssap://com.webos.service.tvpower/power/turnOffScreen")
                } catch {
                    try await client.request("ssap://com.webos.service.tvpower/power/turnOffScreen",
                                             payload: ["standbyMode": "active"])
                }
            }
            setStatus(id, "Off")
        } catch {
            log.error("turnOff \(tv.name) failed: \(error.localizedDescription)")
            setStatus(id, "Turn off failed: \(error.localizedDescription)")
        }
    }

    private func turnOn(_ id: UUID) async {
        guard let tv = store.tv(id) else { return }
        setStatus(id, "Waking…")
        let deadline = Date().addingTimeInterval(90)
        var lastWoL = Date.distantPast
        var lastError = "TV did not respond"

        while !Task.isCancelled, Date() < deadline {
            if Date().timeIntervalSince(lastWoL) > 4 {
                WakeOnLAN.send(mac: tv.mac, ip: tv.ip)
                lastWoL = Date()
            }
            let client = WebOSClient(host: tv.ip, clientKey: tv.clientKey)
            do {
                try await client.connect(pairingTimeout: 5)
                persistKey(id, client)
                if tv.mode == .screenOff {
                    // Errors if the screen is already on; that's fine.
                    _ = try? await client.request("ssap://com.webos.service.tvpower/power/turnOnScreen")
                }
                try await client.request("ssap://tv/switchInput", payload: ["inputId": tv.inputId])
                client.close()
                setStatus(id, "On (\(tv.inputId))")
                return
            } catch {
                lastError = error.localizedDescription
                client.close()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        if !Task.isCancelled {
            log.error("turnOn \(tv.name) failed: \(lastError)")
            setStatus(id, "Wake failed: \(lastError)")
        }
    }

    private func persistKey(_ id: UUID, _ client: WebOSClient) {
        if let key = client.clientKey, store.tv(id)?.clientKey != key {
            store.update(id) { $0.clientKey = key }
        }
    }

    private func setStatus(_ id: UUID, _ text: String) {
        statuses[id] = text
        log.info("\(self.store.tv(id)?.name ?? "?"): \(text)")
    }
}
