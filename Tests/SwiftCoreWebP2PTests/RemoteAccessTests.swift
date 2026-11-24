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

/// A host with `useP2P(remote:)`, a rendezvous and a real TURN server (see `TURNAllocationTests`; skipped without one): a
/// device whose remembered address no longer works still gets through, by the relay.
final class RemoteAccessTests: XCTestCase {
    func testADeviceOnAnotherNetworkReachesTheHostThroughTheRelay() async throws {
        do {
            try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connect(host: "127.0.0.1", port: 34780).get().close()
        } catch { throw XCTSkip("no TURN server on 127.0.0.1:34780") }

        // The rendezvous: an app of its own.
        let rendezvousPort = Int.random(in: 30_000..<45_000)
        let rendezvousBuilder = WebApplication.createBuilder()
        rendezvousBuilder.usePort(rendezvousPort)
        let rendezvousApp = rendezvousBuilder.build()
        P2PRendezvous().mount(on: rendezvousApp)
        Task { try? await rendezvousApp.runAsync() }
        for _ in 0..<100 where !rendezvousApp.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        addTeardownBlock { try? await rendezvousApp.stopAsync() }

        // The host.
        let appPort = Int.random(in: 45_001..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(appPort)
        let remote = P2PRemoteAccess(
            rendezvous: URL(string: "http://127.0.0.1:\(rendezvousPort)")!,
            relay: .init(host: "127.0.0.1", port: 34780, username: "scw", password: "secret")
        )
        let host = try builder.useP2P(storage: InMemoryTunnelStorage(), remote: remote)
        let app = builder.build()
        app.mapGet("/ping") { _ in "pong" }
        addTeardownBlock { try? await app.stopAsync() }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where host.tunnelPort == nil { try await Task.sleep(nanoseconds: 50_000_000) }

        // Pairing happens at home, on the local network.
        let payload = try XCTUnwrap(host.openPairing(host: "127.0.0.1"))
        XCTAssertEqual(payload.rendezvous, remote.rendezvous, "the pairing link carries the rendezvous")
        let storage = InMemoryTunnelStorage()
        let peer = try await SCWPeerConnection.pair(payload, storage: storage)

        // Later, elsewhere: the remembered address answers nothing, and the local network search is not an option.
        let key = "p2p.host.\(peer.hostFingerprint)"
        var record = try JSONDecoder().decode(PeerRecord.self, from: Data(try XCTUnwrap(storage.read(key)).utf8))
        record.host = "127.0.0.1"
        record.port = 1
        storage.write(String(decoding: try JSONEncoder().encode(record), as: UTF8.self), forKey: key)
        let away = try SCWPeerConnection(hostFingerprint: peer.hostFingerprint, storage: storage)
        away.skippedRoutes.withLockedValue { $0 = [.discovered] }

        let base = try await away.start()
        XCTAssertEqual(away.currentRoute, .relay)
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: base.appendingPathComponent("ping"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pong")
        await away.stop()
    }
}
