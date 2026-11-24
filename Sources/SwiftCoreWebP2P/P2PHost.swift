// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import SwiftCoreWeb

/// The host's handle on its peer-to-peer access, returned by `WebApplicationBuilder.useP2P`: pair devices and manage them.
public final class P2PHost: Sendable {
    /// The paired devices, pairing sessions and revocation. `nil` when peer-to-peer is disabled: nothing was created,
    /// and the Keychain was not touched.
    public let pairing: PairingManager?
    private let tunnel: P2PTunnelExtension?

    init(pairing: PairingManager?, tunnel: P2PTunnelExtension?) {
        self.pairing = pairing
        self.tunnel = tunnel
    }

    /// Whether peer-to-peer access was enabled (`useP2P(.enable)`).
    public var isEnabled: Bool { tunnel != nil }

    /// The tunnel's port once the server is running, otherwise `nil`.
    public var tunnelPort: Int? { tunnel?.tunnelPort }

    /// Opens a pairing session and returns what to show as a QR code. `host` is the address the other device will connect
    /// to: an address from `LocalAddresses.ipv4()`, or the machine's Bonjour name. `nil` (and no session opened) when the
    /// server is not running, peer-to-peer is disabled, or `host` is not a valid address.
    public func openPairing(host: String, name: String? = nil, validFor lifetime: TimeInterval = 120) -> PairingPayload? {
        guard let pairing, let port = tunnel?.tunnelPort, let appPort = tunnel?.appPort,
              PairingPayload(host: host, port: port, appPort: appPort, token: "-", hostKeyFingerprint: "-") != nil else { return nil }
        pairing.openPairing(validFor: lifetime)
        return pairing.payload(host: host, port: port, appPort: appPort, name: name)
    }
}
