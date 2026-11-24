// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// What a device remembers about a host it paired with: where to find it and which key to trust (pinning).
struct PeerRecord: Codable, Sendable, Equatable {
    var host: String
    var port: Int
    /// The port of the SCW listener on the host, the only destination the tunnel forwards to.
    var appPort: Int
    /// The host's public key in OpenSSH form.
    var hostKey: String
    var name: String?
    /// Where to look for the host when it is not on this network (`P2PRendezvous`).
    var rendezvous: String? = nil
}
