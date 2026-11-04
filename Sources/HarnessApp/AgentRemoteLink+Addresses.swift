import Darwin
import Foundation

extension AgentRemoteLink {
    struct Address: Identifiable, Equatable {
        let ip: String
        let isTailscale: Bool
        var id: String { ip }
    }

    /// This Mac's IPv4 addresses a device can reach: the home network's, and Tailscale's (100.64.0.0/10) for away from home.
    static func addresses() -> [Address] {
        var result: [Address] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            let tailscale = parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
            if ip.hasPrefix("169.254.") || result.contains(where: { $0.ip == ip }) { continue }
            result.append(Address(ip: ip, isTailscale: tailscale))
        }
        return result.sorted { $0.isTailscale && !$1.isTailscale }
    }
}
