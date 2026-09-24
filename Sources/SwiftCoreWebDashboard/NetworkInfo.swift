// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// The device's LAN IPv4 address, read via POSIX `getifaddrs` — no
/// framework/library needed, just the C sockets API Foundation already
/// links against. Used by the dashboard to show the URL to reach the server
/// from another machine, and by the QR code view.
///
/// Prefers the known interface names (`en0`/`en1` Wi-Fi, `pdp_ip0`
/// cellular) a real device uses; the Simulator shares the Mac's network
/// under whatever interface currently holds the LAN IP (e.g. `en10` over
/// USB Ethernet, or a different `enN` depending on the Mac's hardware), so
/// this falls back to the first UP, non-loopback, non-link-local IPv4
/// address found when none of the preferred names match.
public func localIPAddress() -> String? {
    // `getifaddrs` fills a linked list of every network interface the
    // system knows about (Wi-Fi, cellular, loopback, VPN tunnels, …), each
    // with its own address family (IPv4, IPv6, link-layer). We only care
    // about IPv4 here since that is what a browser/Postman URL needs.
    var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else { return nil }
    // The list is heap-allocated by the C call and must be freed manually
    // once we are done walking it — `defer` guarantees that even if a
    // `guard`/`return` below exits early.
    defer { freeifaddrs(ifaddrPointer) }

    // Walk the linked list (`ifa_next` chains each node to the next) into a
    // Swift array, keeping only IPv4 interfaces that are currently up.
    // `IFF_UP` filters out interfaces the OS knows about but that are
    // administratively down (e.g. an unplugged Ethernet adapter).
    let interfaces = sequence(first: firstAddr, next: { $0.pointee.ifa_next })
        .map { $0.pointee }
        .filter { $0.ifa_addr.pointee.sa_family == UInt8(AF_INET) && ($0.ifa_flags & UInt32(IFF_UP)) != 0 }

    // First choice: the interface names a real device actually uses for
    // Wi-Fi/cellular. On a physical iPhone/iPad this is normally the only
    // match and the fallback below never triggers.
    let preferredNames = ["en0", "en1", "pdp_ip0"]
    let preferred = interfaces.first { preferredNames.contains(String(cString: $0.ifa_name)) }
    // Fallback for the Simulator (and any environment with unfamiliar
    // interface names): take the first non-link-local address. Addresses
    // starting `169.254.` are APIPA/link-local — assigned when there is no
    // real network reachable — and never useful for another machine to
    // connect to, so they're explicitly excluded rather than picked first.
    let fallback = interfaces.first { !ipAddressString(for: $0).hasPrefix("169.254.") }

    guard let match = preferred ?? fallback else { return nil }
    return ipAddressString(for: match)
}

/// Converts one `ifaddrs` entry's raw `sockaddr` into a human-readable
/// dotted-quad string (e.g. `"192.168.1.142"`) via `getnameinfo` with the
/// `NI_NUMERICHOST` flag, which skips any reverse-DNS lookup and just
/// formats the address bytes directly — this needs to stay fast and work
/// offline, so no DNS round-trip is acceptable here.
public func ipAddressString(for interface: ifaddrs) -> String {
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
    return String(cString: host)
}
