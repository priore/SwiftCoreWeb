// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
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
    public struct Relay: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let host: String
        public let port: Int
        public let username: String
        public let password: String
        /// For servers that issue time-limited credentials (`use-auth-secret` in coturn): the secret they share with the host.
        private let sharedSecret: String?
        private let credentialLifetime: TimeInterval

        public var description: String { "Relay(\(host):\(port), user: \(username), password: <redacted>)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["host": host, "port": port, "username": username]) }

        public init(host: String, port: Int = 3478, username: String, password: String) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            sharedSecret = nil
            credentialLifetime = 0
        }

        /// A relay that accepts temporary credentials derived from a shared secret (the TURN REST scheme: user name
        /// `<expiry>:<username>`, password HMAC-SHA1 of it). The secret never leaves the host, and what goes to the TURN
        /// server stops working after `lifetime`; the host asks for a new allocation when that happens. Keep the secret in
        /// the Keychain (`SecretStore`).
        public init(host: String, port: Int = 3478, username: String = "scw", sharedSecret: String, lifetime: TimeInterval = 3600) {
            self.host = host
            self.port = port
            self.username = username
            password = ""
            self.sharedSecret = sharedSecret
            credentialLifetime = lifetime
        }

        /// The user name and password to present now.
        func credentials(now: Date = Date()) -> (username: String, password: String) {
            guard let sharedSecret else { return (username, password) }
            let name = "\(Int(now.timeIntervalSince1970 + credentialLifetime)):\(username)"
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: Data(sharedSecret.utf8)))
            return (name, Data(mac).base64EncodedString())
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
