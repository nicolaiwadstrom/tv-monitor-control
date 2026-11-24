import Foundation

/// `TVConnection` for LG webOS TVs, built on `WebOSClient`.
final class LGWebOSConnection: TVConnection, @unchecked Sendable {
    private let client: WebOSClient
    private var muted = false

    init(host: String, credential: String?) {
        client = WebOSClient(host: host, clientKey: credential)
    }

    var credential: String? { client.clientKey }
    var isAlive: Bool { client.isAlive }

    func connect(pairingTimeout: TimeInterval) async throws {
        try await client.connect(pairingTimeout: pairingTimeout)
    }

    func close() { client.close() }

    func listInputs() async -> [String] {
        guard let reply = try? await client.request("ssap://tv/getExternalInputList"),
              let devices = reply["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { $0["id"] as? String }
    }

    func turnOff(mode: PowerMode) async throws {
        switch mode {
        case .powerOff:
            try await client.request("ssap://system/turnOff")
        case .screenOff:
            let uri = "ssap://com.webos.service.tvpower/power/turnOffScreen"
            do {
                try await client.request(uri)
            } catch {
                try await client.request(uri, payload: ["standbyMode": "active"])
            }
        }
    }

    func turnOn(mode: PowerMode, input: String) async throws {
        if mode == .screenOff {
            // Errors if the screen is already on; that's fine.
            _ = try? await client.request("ssap://com.webos.service.tvpower/power/turnOnScreen")
        }
        try await client.request("ssap://tv/switchInput", payload: ["inputId": input])
    }

    func volumeUp() async throws { try await client.request("ssap://audio/volumeUp") }
    func volumeDown() async throws { try await client.request("ssap://audio/volumeDown") }

    func toggleMute() async throws {
        var current = muted
        if let status = try? await client.request("ssap://audio/getStatus"),
           let m = status["mute"] as? Bool { current = m }
        try await client.request("ssap://audio/setMute", payload: ["mute": !current])
        muted = !current
    }
}
