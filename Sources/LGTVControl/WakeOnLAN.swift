import Foundation
import Darwin

enum WakeOnLAN {
    static func parse(mac: String) -> [UInt8]? {
        let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        return bytes.count == 6 ? bytes : nil
    }

    /// Sends a magic packet to every interface's broadcast address, to 255.255.255.255,
    /// and (unicast) to the TV's own IP.
    static func send(mac: String, ip: String?) {
        guard let macBytes = parse(mac: mac) else { return }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += macBytes }

        var targets = Set(broadcastAddresses())
        targets.insert("255.255.255.255")
        if let ip, !ip.isEmpty { targets.insert(ip) }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        for target in targets {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(9).bigEndian
            guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func broadcastAddresses() -> [String] {
        var result: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_BROADCAST != 0,
                  let dst = ifa.ifa_dstaddr else { continue }
            var sin = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            result.append(String(cString: buf))
        }
        return result
    }

    /// Looks up the MAC for an IP in the ARP cache (pings once first to populate it).
    static func lookupMAC(ip: String) async -> String? {
        await Task.detached { () -> String? in
            _ = run("/sbin/ping", ["-c", "1", "-t", "2", ip])
            guard let out = run("/usr/sbin/arp", ["-n", ip]),
                  let range = out.range(of: " at ") else { return nil }
            let token = out[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            let parts = token.split(separator: ":")
            guard parts.count == 6 else { return nil }
            return parts.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
        }.value
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
