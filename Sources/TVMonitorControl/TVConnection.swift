import Foundation

/// The kinds of TV this app can control. Add a case here (plus a connection class
/// implementing `TVConnection`) to support another brand/protocol.
enum TVType: String, Codable, CaseIterable, Identifiable {
    case lgWebOS

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lgWebOS: return "LG (WebOS)"
        }
    }

    /// Default name for a newly added TV of this type.
    var defaultName: String {
        switch self {
        case .lgWebOS: return "LG TV"
        }
    }

    /// Instructions shown at the bottom of the settings editor.
    var setupHelp: String {
        switch self {
        case .lgWebOS:
            return "On the TV, enable Wake-on-LAN (Settings → General → Devices → External Devices → TV On With Mobile → Turn on via Wi-Fi; applies to Ethernet too). Screen-off mode keeps the TV reachable and wakes fastest."
        }
    }

    /// Creates an (unconnected) connection to a TV of this type.
    func makeConnection(host: String, credential: String?) -> TVConnection {
        switch self {
        case .lgWebOS: return LGWebOSConnection(host: host, credential: credential)
        }
    }
}

/// A connection to one TV. Implementations hide the brand-specific protocol.
protocol TVConnection: AnyObject, Sendable {
    /// Pairing credential (e.g. a client key) to persist after connecting; nil if none.
    var credential: String? { get }
    /// True while the connection is usable.
    var isAlive: Bool { get }

    /// Connects, pairing if needed. `pairingTimeout` is how long to wait for the user
    /// to accept a prompt on the TV.
    func connect(pairingTimeout: TimeInterval) async throws
    func close()

    /// Names of the TV's selectable inputs (empty if unsupported).
    func listInputs() async -> [String]
    /// Turns the TV off, honouring the configured power mode.
    func turnOff(mode: PowerMode) async throws
    /// Called once connected after a wake: bring the panel on and switch to `input`.
    func turnOn(mode: PowerMode, input: String) async throws

    func volumeUp() async throws
    func volumeDown() async throws
    func toggleMute() async throws
}
