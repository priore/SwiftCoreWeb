// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

public enum TunnelError: Error, Sendable, Equatable {
    /// The host presented a key other than the one the client was paired with.
    case untrustedHostKey
    /// The destination is not on the allow-list.
    case destinationNotAllowed
    /// The host did not accept this device's key.
    case authenticationRefused
    /// The host is already serving its maximum number of connections.
    case tooManyConnections
    /// The secret storage refused to keep a key: pairing cannot be made durable.
    case storageUnavailable
    /// The pairing link is not a complete payload, or the pairing token was not accepted.
    case pairingFailed
    /// The tunnel is not connected (or the connection was lost).
    case notConnected
}
