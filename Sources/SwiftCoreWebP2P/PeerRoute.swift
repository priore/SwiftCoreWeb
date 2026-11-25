// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// The way a device reached its host, for diagnostics.
public enum PeerRoute: Sendable, Hashable {
    /// Directly, at the address remembered from pairing.
    case local
    /// Directly, at an address found again on the local network.
    case discovered
    /// Directly across the internet: both sides opened a TCP connection to each other at the same time (hole punching),
    /// so no relay carries the bytes. Works only through some NATs.
    case direct
    /// Through the TURN relay, from another network. The relay carries the tunnel's encrypted bytes and cannot read them.
    case relay
}
