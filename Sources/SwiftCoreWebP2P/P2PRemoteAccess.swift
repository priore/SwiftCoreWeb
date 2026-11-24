// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// What a host needs to be reachable from another network (4G/5G, another Wi-Fi): a rendezvous where devices find it, and a
/// TURN server that relays their connection. Neither can read the traffic: it is SSH between the device and the host.
///
/// ```swift
/// let remote = P2PRemoteAccess(
///     rendezvous: URL(string: "https://rendezvous.example.com")!,        // an app that mounted P2PRendezvous
///     relay: .init(host: "turn.example.com", port: 3478, username: "scw", password: secret)  // secret from SecretStore
/// )
/// let p2p = try builder.useP2P(remote: remote)
/// ```
public struct P2PRemoteAccess: Sendable {
    /// A TURN server that allows TCP allocations (RFC 6062), with its long-term credentials. Keep the password in the
    /// Keychain (`SecretStore`), never in a file.
    public struct Relay: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let host: String
        public let port: Int
        public let username: String
        public let password: String

        public var description: String { "Relay(\(host):\(port), user: \(username), password: <redacted>)" }
        public var debugDescription: String { description }

        public init(host: String, port: Int = 3478, username: String, password: String) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    /// The base URL of an app that mounted `P2PRendezvous`.
    public let rendezvous: URL
    public let relay: Relay

    public init(rendezvous: URL, relay: Relay) {
        self.rendezvous = rendezvous
        self.relay = relay
    }
}
