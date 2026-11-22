import Foundation

enum PowerMode: String, Codable, CaseIterable, Identifiable {
    /// TV stays in "active standby": panel is off, network stays up, wakes fast.
    case screenOff
    /// Full standby. Waking relies on Wake-on-LAN.
    case powerOff

    var id: String { rawValue }
    var label: String {
        switch self {
        case .screenOff: return "Screen off (panel off, fast wake)"
        case .powerOff: return "Full power off (wake via Wake-on-LAN)"
        }
    }
}

enum VolumeMode: String, Codable, CaseIterable, Identifiable {
    case off
    /// Volume keys control this TV only while the Mac's audio output is HDMI/DisplayPort.
    case whenDisplayAudio
    case always

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off (don't touch volume keys)"
        case .whenDisplayAudio: return "On, when audio output is HDMI/DisplayPort"
        case .always: return "On, always"
        }
    }
}

struct TVConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "LG TV"
    var ip = ""
    var mac = ""
    var inputId = "HDMI_1"
    var mode: PowerMode = .screenOff
    var enabled = true
    var clientKey: String?
    var knownInputs: [String] = []
    var volumeMode: VolumeMode = .off

    init() {}

    // Tolerant decoding so config files written by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "LG TV"
        ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? ""
        mac = try c.decodeIfPresent(String.self, forKey: .mac) ?? ""
        inputId = try c.decodeIfPresent(String.self, forKey: .inputId) ?? "HDMI_1"
        mode = try c.decodeIfPresent(PowerMode.self, forKey: .mode) ?? .screenOff
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        clientKey = try c.decodeIfPresent(String.self, forKey: .clientKey)
        knownInputs = try c.decodeIfPresent([String].self, forKey: .knownInputs) ?? []
        volumeMode = try c.decodeIfPresent(VolumeMode.self, forKey: .volumeMode) ?? .off
    }
}

/// Persists the TV list as JSON in ~/Library/Application Support/LGTVControl/config.json.
/// The file holds pairing keys, so it is written with 0600 permissions.
@MainActor
final class ConfigStore: ObservableObject {
    @Published var tvs: [TVConfig] = [] {
        didSet { save() }
    }

    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LGTVControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([TVConfig].self, from: data) {
            tvs = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tvs) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func update(_ id: UUID, _ change: (inout TVConfig) -> Void) {
        guard let i = tvs.firstIndex(where: { $0.id == id }) else { return }
        change(&tvs[i])
    }

    func tv(_ id: UUID) -> TVConfig? { tvs.first { $0.id == id } }
}
