// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// How a client proves itself to the host.
enum TunnelCredential: Sendable {
    /// A paired device's key.
    case key
    /// The one-time pairing token, offered once to register this device's key.
    case pairing(token: String)
}
