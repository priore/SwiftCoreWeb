// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Network
import NIOConcurrencyHelpers
import os
import SwiftCoreWeb

private let p2pLogger = Logger(subsystem: "SwiftCoreWebP2P", category: "tunnel")

/// Runs the SSH tunnel and its Bonjour announcement next to the SCW server, for as long as the server runs.
final class P2PTunnelExtension: ServerExtension {
    static let bonjourType = "_scw-p2p._tcp"

    private struct Running {
        let server: SSHTunnelServer
        let advertiser: NWListener?
    }

    private static let portKey = "p2p.tunnel-port"

    private let pairing: PairingManager
    private let storage: TunnelSecretStorage
    private let name: String
    private let requestedPort: Int
    private let running = NIOLockedValueBox<Running?>(nil)
    private let boundPort = NIOLockedValueBox<Int?>(nil)

    init(pairing: PairingManager, storage: TunnelSecretStorage, name: String, port: Int) {
        self.pairing = pairing
        self.storage = storage
        self.name = name
        self.requestedPort = port
    }

    var tunnelPort: Int? { boundPort.withLockedValue { $0 } }

    func start(ingress: RequestIngress) async throws {
        await stop() // a restart of the server starts the tunnel again
        // Paired devices remember the port, so it is reused across launches when it is free; a random one is the fallback.
        let remembered = storage.read(Self.portKey).flatMap(Int.init)
        let candidates = requestedPort != 0 ? [requestedPort] : [remembered, 0].compactMap { $0 }
        var started: (server: SSHTunnelServer, port: Int)?
        var lastError: Error = TunnelError.notConnected
        for candidate in candidates {
            let server = SSHTunnelServer(pairing: pairing, allowList: TunnelAllowList(port: ingress.port))
            do {
                started = (server, try await server.start(port: candidate))
                break
            } catch {
                lastError = error
                await server.stop()
            }
        }
        guard let (server, port) = started else { throw lastError }
        storage.write(String(port), forKey: Self.portKey)
        let advertiser = Self.advertise(name: name, port: port)
        running.withLockedValue { $0 = Running(server: server, advertiser: advertiser) }
        boundPort.withLockedValue { $0 = port }
    }

    func stop() async {
        boundPort.withLockedValue { $0 = nil }
        guard let current = running.withLockedValue({ $0.take() }) else { return }
        current.advertiser?.cancel()
        await current.server.stop()
    }

    /// Announces `_scw-p2p._tcp` on the tunnel's port. The announcement is a convenience (a device on the LAN finds the host
    /// without typing an address): when it cannot start the tunnel still works through the pairing payload.
    private static func advertise(name: String, port: Int) -> NWListener? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)), let listener = try? NWListener(using: .tcp, on: nwPort) else {
            p2pLogger.error("Bonjour announcement could not start")
            return nil
        }
        listener.service = NWListener.Service(name: name, type: bonjourType)
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { p2pLogger.error("Bonjour announcement failed: \(String(describing: error), privacy: .public)") }
        }
        // This listener only announces; the SSH server bound to the same port serves the connections.
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global(qos: .utility))
        return listener
    }
}
