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
    /// dns_sd requires a serial queue, and the reference must be deallocated on that same queue.
    private let queue = DispatchQueue(label: "SwiftCoreWebP2P.bonjour", qos: .utility)

    /// `name` `nil` announces under the system's own name for the device. Fails (`nil`) when the announcement cannot be
    /// registered: it is a convenience, the tunnel works without it.
    init?(name: String?, type: String, port: Int, txt: [String: String] = [:]) {
        guard let port = UInt16(exactly: port) else { return nil }
        var created: DNSServiceRef?
        let record = Self.txtRecord(txt)
        let status = DNSServiceRegister(&created, 0, 0, name.map(Self.truncated), type, nil, nil, port.bigEndian, UInt16(record.count), record.isEmpty ? nil : record, nil, nil)
        guard status == kDNSServiceErr_NoError, let created else { return nil }
        guard DNSServiceSetDispatchQueue(created, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(created)
            return nil
        }
        reference = created
    }

    func cancel() {
        queue.sync {
            guard let current = reference else { return }
            reference = nil
            DNSServiceRefDeallocate(current)
        }
    }

    deinit { cancel() }

    /// TXT wire format: each entry is a length byte followed by `key=value`, at most 255 bytes.
    private static func txtRecord(_ entries: [String: String]) -> [UInt8] {
        entries.sorted { $0.key < $1.key }.flatMap { key, value -> [UInt8] in
            let bytes = Array("\(key)=\(value)".utf8.prefix(255))
            return [UInt8(bytes.count)] + bytes
        }
    }

    /// A service name is at most 63 bytes of UTF-8.
    private static func truncated(_ name: String) -> String {
        var result = name
        while result.utf8.count > 63 { result.removeLast() }
        return result
    }
}
