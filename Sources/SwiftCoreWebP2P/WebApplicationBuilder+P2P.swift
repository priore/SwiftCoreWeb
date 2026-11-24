// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import SwiftCoreWeb

extension WebApplicationBuilder {
    /// Adds peer-to-peer access: paired devices reach this app's routes through an SSH tunnel, with no port forwarding
    /// and no server in between. Nothing runs unless this is called; the tunnel starts and stops with the server.
    ///
    /// - Parameters:
    ///   - mode: `.disable` leaves peer-to-peer off (for a setting the user can turn off): nothing starts and the storage is
    ///     not touched. This is an on/off switch for the whole feature; exposing individual routes to or hiding them from paired
    ///     devices is a separate, later step.
    ///   - name: the name announced on the local network (Bonjour); `nil` uses the system's name for the device.
    ///   - port: the tunnel's port. `0` (default) reuses the port of the last run when it is free, else picks one: devices
    ///     paired earlier keep finding the host. Read the actual port from `P2PHost.tunnelPort`.
    ///   - storage: where the host key and paired devices are kept; the Keychain by default.
    /// Throws when the storage cannot hold the host key (`storageUnavailable`) or holds one that cannot be read
    /// (`corruptedStorage`). If the tunnel's port is given and busy at start, the server does not start.
    ///
    /// On iOS the hosting app must declare `_scw-p2p._tcp` in `NSBonjourServices` and a `NSLocalNetworkUsageDescription`.
    @discardableResult
    public func useP2P(
        _ mode: P2PMode = .enable,
        name: String? = nil,
        port: Int = 0,
        storage: TunnelSecretStorage = KeychainTunnelStorage()
    ) throws -> P2PHost {
        // Disabled means untouched: no host key is created and the storage is not read.
        guard mode == .enable else { return P2PHost(pairing: nil, tunnel: nil) }
        let pairing = try PairingManager(storage: storage)
        let tunnel = P2PTunnelExtension(pairing: pairing, storage: storage, name: name, port: port)
        addExtension(tunnel)
        return P2PHost(pairing: pairing, tunnel: tunnel)
    }
}
