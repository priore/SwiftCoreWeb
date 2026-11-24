// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import dnssd
import Foundation

/// Announces a TCP service on the local network without opening a socket of its own: the tunnel's server keeps its port
/// to itself (a second listener announcing on the same port would take over the IPv6 side of it).
final class BonjourAdvertiser: @unchecked Sendable {
    private var reference: DNSServiceRef?

    /// `name` `nil` announces under the system's own name for the device. Fails (`nil`) when the announcement cannot be
    /// registered: it is a convenience, the tunnel works without it.
    init?(name: String?, type: String, port: Int) {
        guard let port = UInt16(exactly: port) else { return nil }
        var created: DNSServiceRef?
        let status = DNSServiceRegister(&created, 0, 0, name.map(Self.truncated), type, nil, nil, port.bigEndian, 0, nil, nil, nil)
        guard status == kDNSServiceErr_NoError, let created else { return nil }
        reference = created
        DNSServiceSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
    }

    func cancel() {
        guard let current = reference else { return }
        reference = nil
        DNSServiceRefDeallocate(current)
    }

    deinit { cancel() }

    /// A service name is at most 63 bytes of UTF-8.
    private static func truncated(_ name: String) -> String {
        var result = name
        while result.utf8.count > 63 { result.removeLast() }
        return result
    }
}
