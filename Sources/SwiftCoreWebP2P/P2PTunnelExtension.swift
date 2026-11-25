// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOConcurrencyHelpers
import os
import SwiftCoreWeb

private let p2pLogger = Logger(subsystem: "SwiftCoreWebP2P", category: "tunnel")

/// Runs the SSH tunnel and its Bonjour announcement next to the SCW server, for as long as the server runs.
final class P2PTunnelExtension: ServerExtension {
    static let bonjourType = "_scw-p2p._tcp"

    private struct Running {
        let server: SSHTunnelServer
        let advertiser: BonjourAdvertiser?
        let remote: RemoteAccessPublisher?
    }

    private static let portKey = "p2p.tunnel-port"

    private let pairing: PairingManager
    private let storage: TunnelSecretStorage
    private let name: String?
    private let requestedPort: Int
    let remote: P2PRemoteAccess?
    private let running = NIOLockedValueBox<Running?>(nil)
    private let boundPort = NIOLockedValueBox<Int?>(nil)
    private let servedAppPort = NIOLockedValueBox<Int?>(nil)
    private let servedPeer = NIOLockedValueBox<PeerEndpoint?>(nil)
    /// The core's peer listener this tunnel forwards through (visible to tests).
    var peer: PeerEndpoint? { servedPeer.withLockedValue { $0 } }

    init(pairing: PairingManager, storage: TunnelSecretStorage, name: String?, port: Int, remote: P2PRemoteAccess? = nil) {
        self.remote = remote
        self.pairing = pairing
        self.storage = storage
        self.name = name
        self.requestedPort = port
    }

    var tunnelPort: Int? { boundPort.withLockedValue { $0 } }
    /// The HTTP port the tunnel forwards to, known once the server runs.
    var appPort: Int? { servedAppPort.withLockedValue { $0 } }

    func start(ingress: RequestIngress) async throws {
        await stop() // a restart of the server starts the tunnel again
        // Without the peer listener every device would reach the app as 127.0.0.1 (no rate limit): refuse to run that way.
        guard let peer = ingress.peer else { throw TunnelError.notConnected }
        // Paired devices remember the port, so it is reused across launches when it is free; a random one is the fallback.
        let remembered = storage.read(Self.portKey).flatMap(Int.init)
        let candidates = requestedPort != 0 ? [requestedPort] : [remembered, 0].compactMap { $0 }
        var started: (server: SSHTunnelServer, port: Int)?
        var lastError: Error = TunnelError.notConnected
        for candidate in candidates {
            let server = SSHTunnelServer(pairing: pairing, allowList: TunnelAllowList(port: ingress.port), peer: peer)
            do {
                started = (server, try await server.start(port: candidate))
                break
            } catch {
                lastError = error
                await server.stop()
            }
        }
        guard let (server, port) = started else { throw lastError }
        if remembered != port { storage.write(String(port), forKey: Self.portKey) }
        servedAppPort.withLockedValue { $0 = ingress.port }
        servedPeer.withLockedValue { $0 = peer }
        let advertiser = BonjourAdvertiser(name: name, type: Self.bonjourType, port: port, txt: [PeerDiscovery.fingerprintKey: pairing.hostFingerprint, PeerDiscovery.appPortKey: String(ingress.port)])
        if advertiser == nil { p2pLogger.error("Bonjour announcement could not start") }
        let publisher = remote.map { RemoteAccessPublisher(remote: $0, pairing: pairing, server: server) }
        publisher?.start()
        running.withLockedValue { $0 = Running(server: server, advertiser: advertiser, remote: publisher) }
        boundPort.withLockedValue { $0 = port }
    }

    func stop() async {
        boundPort.withLockedValue { $0 = nil }
        servedAppPort.withLockedValue { $0 = nil }
        servedPeer.withLockedValue { $0 = nil }
        guard let current = running.withLockedValue({ $0.take() }) else { return }
        current.advertiser?.cancel()
        await current.remote?.stop()
        await current.server.stop()
    }
}
