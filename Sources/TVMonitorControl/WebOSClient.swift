import Foundation

enum WebOSError: LocalizedError {
    case timeout
    case closed
    case rejected(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "Timed out"
        case .closed: return "Connection closed"
        case .rejected(let s): return "Rejected by TV: \(s)"
        case .failed(let s): return s
        }
    }
}

/// Minimal client for the LG webOS "SSAP" WebSocket API (wss :3001, falling back to ws :3000).
final class WebOSClient: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    private struct Waiter {
        let token: UUID
        let cont: CheckedContinuation<[String: Any], Error>
    }

    private let host: String
    private(set) var clientKey: String?

    private let queue = DispatchQueue(label: "tvmonitorcontrol.webos.client")
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var waiters: [String: Waiter] = [:]
    private var counter = 0
    private var alive = false

    /// True after a successful register until the socket closes or fails.
    var isAlive: Bool { queue.sync { alive } }

    init(host: String, clientKey: String?) {
        self.host = host
        self.clientKey = clientKey
    }

    // MARK: Public API

    /// Connects and registers. With no stored key the TV shows a pairing prompt;
    /// `pairingTimeout` is how long to wait for the user to accept it.
    func connect(pairingTimeout: TimeInterval) async throws {
        var lastError: Error = WebOSError.failed("Could not connect")
        for urlString in ["wss://\(host):3001", "ws://\(host):3000"] {
            do {
                try await open(URL(string: urlString)!)
                try await register(timeout: pairingTimeout)
                return
            } catch let e as WebOSError {
                close()
                if case .rejected = e { throw e }
                lastError = e
            } catch {
                close()
                lastError = error
            }
        }
        throw lastError
    }

    @discardableResult
    func request(_ uri: String, payload: [String: Any] = [:], timeout: TimeInterval = 10) async throws -> [String: Any] {
        let id = nextId()
        let message: [String: Any] = ["id": id, "type": "request", "uri": uri, "payload": payload]
        let text = try Self.encode(message)
        let reply = try await wait(id: id, timeout: timeout) { [self] in
            socket?.send(.string(text)) { _ in }
        }
        if let ok = reply["returnValue"] as? Bool, ok == false {
            throw WebOSError.failed(reply["errorText"] as? String ?? "Request failed")
        }
        return reply
    }

    func close() {
        queue.async { [self] in
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            session?.invalidateAndCancel()
            session = nil
            failAll(WebOSError.closed)
        }
    }

    // MARK: Connection

    private func open(_ url: URL) async throws {
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = s.webSocketTask(with: url)
        queue.sync {
            session = s
            socket = task
        }
        _ = try await wait(id: "__open__", timeout: 4) { task.resume() }
        listen(task)
    }

    private func register(timeout: TimeInterval) async throws {
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": Self.manifest,
        ]
        if let key = clientKey { payload["client-key"] = key }
        let text = try Self.encode(["id": "register_0", "type": "register", "payload": payload])
        let reply = try await wait(id: "register_0", timeout: timeout) { [self] in
            socket?.send(.string(text)) { _ in }
        }
        if let key = (reply["payload"] as? [String: Any])?["client-key"] as? String {
            clientKey = key
        }
        queue.sync { alive = true }
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.queue.async { self.failAll(error) }
            case .success(let message):
                var text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: break
                }
                if let text,
                   let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    self.queue.async { self.handle(obj) }
                }
                self.listen(task)
            }
        }
    }

    private func handle(_ obj: [String: Any]) {
        guard let id = obj["id"] as? String, let type = obj["type"] as? String else { return }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        switch type {
        case "registered":
            resolve(id, .success(obj))
        case "error":
            resolve(id, .failure(WebOSError.rejected(obj["error"] as? String ?? "unknown error")))
        case "response":
            // The first reply to "register" only says the pairing prompt is showing.
            if id.hasPrefix("register") { return }
            resolve(id, .success(payload))
        default:
            break
        }
    }

    // MARK: Waiters (all state mutated on `queue`)

    private func wait(id: String, timeout: TimeInterval, start: @escaping () -> Void) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            let token = UUID()
            queue.async {
                self.waiters[id] = Waiter(token: token, cont: cont)
                start()
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                if let w = self.waiters[id], w.token == token {
                    self.waiters[id] = nil
                    w.cont.resume(throwing: WebOSError.timeout)
                }
            }
        }
    }

    private func resolve(_ id: String, _ result: Result<[String: Any], Error>) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        w.cont.resume(with: result)
    }

    private func failAll(_ error: Error) {
        alive = false
        let all = waiters
        waiters.removeAll()
        for (_, w) in all { w.cont.resume(throwing: error) }
    }

    private func nextId() -> String {
        queue.sync {
            counter += 1
            return "req_\(counter)"
        }
    }

    // MARK: Delegates

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // LG TVs use a self-signed certificate on :3001; we only talk to the user-configured LAN IP.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async { self.resolve("__open__", .success([:])) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { self.failAll(error ?? WebOSError.closed) }
    }

    // MARK: Helpers

    private static func encode(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    private static let manifest: [String: Any] = [
        "manifestVersion": 1,
        "appVersion": "1.1",
        "permissions": [
            "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED",
            "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_RECORDING",
            "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV", "CONTROL_POWER", "CONTROL_TV_SCREEN",
            "CONTROL_TV_STANBY", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD",
            "READ_APP_STATUS", "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE",
            "READ_RUNNING_APPS", "READ_TV_CHANNEL_LIST", "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE",
            "READ_COUNTRY_INFO", "READ_SETTINGS", "READ_INSTALLED_APPS",
        ],
    ]
}
