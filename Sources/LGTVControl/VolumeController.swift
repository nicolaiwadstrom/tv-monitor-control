import AppKit
import Combine
import Foundation

enum VolumeAction {
    case up, down, toggleMute
}

/// Sends volume commands to TVs over persistent connections (reconnecting as needed),
/// so key-repeat stays responsive.
@MainActor
final class VolumeController {
    private let store: ConfigStore
    private let isActive: () -> Bool
    private var clients: [UUID: WebOSClient] = [:]
    private var chains: [UUID: Task<Void, Never>] = [:]
    private var pending: [UUID: Int] = [:]
    private var muted: [UUID: Bool] = [:]
    private var lastFailure: [UUID: Date] = [:]

    init(store: ConfigStore, isActive: @escaping () -> Bool) {
        self.store = store
        self.isActive = isActive
    }

    func send(_ action: VolumeAction, to ids: [UUID]) {
        guard isActive() else { return }
        for id in ids { enqueue(action, id) }
    }

    func disconnectAll() {
        clients.values.forEach { $0.close() }
        clients.removeAll()
    }

    private func enqueue(_ action: VolumeAction, _ id: UUID) {
        // Avoid a backlog (and overshoot after key release) when a TV is slow or unreachable.
        guard pending[id, default: 0] < 4 else { return }
        if let t = lastFailure[id], Date().timeIntervalSince(t) < 5 { return }
        pending[id, default: 0] += 1
        let previous = chains[id]
        chains[id] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.perform(action, id)
            self.pending[id, default: 1] -= 1
        }
    }

    private func perform(_ action: VolumeAction, _ id: UUID) async {
        guard let tv = store.tv(id) else { return }
        for _ in 0..<2 {
            do {
                let client = try await connected(tv)
                switch action {
                case .up:
                    try await client.request("ssap://audio/volumeUp")
                case .down:
                    try await client.request("ssap://audio/volumeDown")
                case .toggleMute:
                    var current = muted[id] ?? false
                    if let status = try? await client.request("ssap://audio/getStatus"),
                       let m = status["mute"] as? Bool { current = m }
                    try await client.request("ssap://audio/setMute", payload: ["mute": !current])
                    muted[id] = !current
                }
                lastFailure[id] = nil
                return
            } catch {
                clients[id]?.close()
                clients[id] = nil
            }
        }
        lastFailure[id] = Date()
    }

    private func connected(_ tv: TVConfig) async throws -> WebOSClient {
        if let c = clients[tv.id], c.isAlive { return c }
        clients[tv.id]?.close()
        let c = WebOSClient(host: tv.ip, clientKey: tv.clientKey)
        try await c.connect(pairingTimeout: 5)
        clients[tv.id] = c
        return c
    }
}

/// Owns the media-key tap: installs it only while at least one TV has volume control enabled,
/// and routes key presses to the matching TVs.
@MainActor
final class VolumeKeyService {
    private let store: ConfigStore
    private let volume: VolumeController
    private let tap = MediaKeyTap()
    private var cancellable: AnyCancellable?
    private var retryTimer: Timer?
    private var prompted = false

    /// True when volume control is wanted but the Accessibility permission is missing.
    private(set) var needsPermission = false

    init(store: ConfigStore, volume: VolumeController) {
        self.store = store
        self.volume = volume
        tap.handler = { [weak self] key, isDown, isRepeat, mods in
            self?.handle(key, isDown: isDown, isRepeat: isRepeat, modifiers: mods) ?? false
        }
    }

    func start() {
        cancellable = store.$tvs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let wanted = store.tvs.contains { $0.enabled && $0.volumeMode != .off }
        guard wanted else {
            tap.stop()
            retryTimer?.invalidate()
            needsPermission = false
            return
        }
        if tap.isRunning { needsPermission = false; return }

        if AXIsProcessTrusted(), tap.start() {
            needsPermission = false
            retryTimer?.invalidate()
            return
        }
        needsPermission = true
        if !prompted {
            prompted = true
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if retryTimer?.isValid != true {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func handle(_ key: MediaKey, isDown: Bool, isRepeat: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Leave option/shift/cmd/ctrl combos to macOS (e.g. option+volume opens Sound settings).
        guard modifiers.intersection([.option, .shift, .command, .control]).isEmpty else { return false }

        var displayAudio: Bool?
        let targets = store.tvs.filter { tv in
            guard tv.enabled else { return false }
            switch tv.volumeMode {
            case .off: return false
            case .always: return true
            case .whenDisplayAudio:
                if displayAudio == nil { displayAudio = AudioOutput.isDisplayAudio() }
                return displayAudio == true
            }
        }
        guard !targets.isEmpty else { return false }

        if isDown {
            switch key {
            case .volumeUp: volume.send(.up, to: targets.map(\.id))
            case .volumeDown: volume.send(.down, to: targets.map(\.id))
            case .mute: if !isRepeat { volume.send(.toggleMute, to: targets.map(\.id)) }
            }
        }
        return true
    }
}
