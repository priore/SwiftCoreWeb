// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Darwin
import Foundation

/// The device's own IPv4 addresses on its network interfaces, loopback excluded, Wi-Fi and Ethernet first: where another
/// device on the same network can reach this one.
public enum LocalAddresses {
    public static func ipv4() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  Int32(interface.ifa_flags) & IFF_UP != 0, Int32(interface.ifa_flags) & IFF_RUNNING != 0, Int32(interface.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: buffer)
            if !found.contains(where: { $0.address == text }) { found.append((String(cString: interface.ifa_name), text)) }
        }
        // Wi-Fi and Ethernet (`en*`) first: cellular, VPN and bridge interfaces are rarely where a nearby device connects.
        return found.sorted { ($0.interface.hasPrefix("en") ? 0 : 1) < ($1.interface.hasPrefix("en") ? 0 : 1) }.map(\.address)
    }
}
