// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// A device that completed pairing and may connect with its key.
public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    /// The device key's fingerprint (`TunnelFingerprint`).
    public let id: String
    public var name: String
    /// The device's public key in OpenSSH form (`ssh-ed25519 AAAA...`).
    public let publicKey: String
    public let pairedAt: Date
    /// `true` once the host's own side changed the name (`PairingManager.rename`): a later pairing of the same device does
    /// not overwrite it with the name the device sends. `nil` for lists saved before this existed.
    public var nameSetByHost: Bool? = nil
}
