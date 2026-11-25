// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import NIOCore
import NIOPosix
import SwiftCoreWeb
@testable import SwiftCoreWebP2P

/// The whole tunnel through a TURN relay: pairing and requests from a device that only knows the relayed address.
/// Needs the coturn described in `TURNAllocationTests` (skipped otherwise).
final class RelayTunnelTests: XCTestCase {
    func testPairingAndRequestsThroughTheRelay() async throws {
        do {
            try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connect(host: "127.0.0.1", port: 34780).get().close()
        } catch { throw XCTSkip("no TURN server on 127.0.0.1:34780") }

        let appPort = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(appPort)
        let app = builder.build()
        app.mapGet("/ping") { _ in "pong" }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where !app.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        addTeardownBlock { try? await app.stopAsync() }

        let pairing = try PairingManager(storage: InMemoryTunnelStorage())
        let server = SSHTunnelServer(pairing: pairing, allowList: TunnelAllowList(port: appPort))
        addTeardownBlock { await server.stop() }

        let allocation = try await TURNAllocation.allocate(server: "127.0.0.1", port: 34780, credentials: .init(username: "scw", password: "secret"))
        addTeardownBlock { await allocation.close() }
        try await allocation.permit(ip: "127.0.0.1")
        let serving = Task {
            for await attempt in allocation.attempts {
                try? await allocation.accept(attempt) { server.serve($0) }
            }
        }
        addTeardownBlock { serving.cancel() }

        // The device knows only the relayed address and the pairing token: the server never listens on a port it published.
        pairing.openPairing()
        let payload = try XCTUnwrap(pairing.payload(host: allocation.relayedHost, port: allocation.relayedPort, appPort: appPort, name: "Relayed host"))
        let peer = try await SCWPeerConnection.pair(payload, storage: InMemoryTunnelStorage())
        let base = try await peer.start()
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: base.appendingPathComponent("ping"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pong")
        await peer.stop()
    }
}
