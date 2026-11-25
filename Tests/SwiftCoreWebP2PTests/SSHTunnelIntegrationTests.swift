// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import SwiftCoreWeb
@testable import SwiftCoreWebP2P

/// A real SCW app on the loopback, an SSH tunnel server in front of it, and paired clients: a plain `URLSession`
/// talks to the app through the tunnel.
final class SSHTunnelIntegrationTests: XCTestCase {
    private struct Fixture {
        let app: WebApplication
        let appPort: Int
        let pairing: PairingManager
        let server: SSHTunnelServer
        let serverPort: Int
    }

    private func makeFixture(handshakeTimeout: TimeAmount = .seconds(10), maxConnections: Int = 64) async throws -> Fixture {
        let appPort = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(appPort)
        let app = builder.build()
        app.mapGet("/ping") { _ in "pong" }
        app.mapWebSocket("/ws-echo") { socket in
            for try await message in socket.messages() {
                if case .text(let text) = message { try await socket.send("echo: " + text) }
            }
        }
        app.mapPost("/echo") { ctx in String(decoding: ctx.request.body, as: UTF8.self) }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where !app.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }

        let pairing = try PairingManager(storage: InMemoryTunnelStorage())
        let server = SSHTunnelServer(pairing: pairing, allowList: TunnelAllowList(port: appPort), handshakeTimeout: handshakeTimeout, maxConnections: maxConnections)
        let fixture = Fixture(app: app, appPort: appPort, pairing: pairing, server: server, serverPort: try await server.start(host: "127.0.0.1"))
        addTeardownBlock { await Self.stop(fixture) } // also runs when a step in between throws
        return fixture
    }

    private static func stop(_ fixture: Fixture) async {
        await fixture.server.stop()
        try? await fixture.app.stopAsync()
    }

    /// Opens a pairing session and returns the payload a device would scan.
    private func payload(_ fixture: Fixture) throws -> PairingPayload {
        fixture.pairing.openPairing()
        return try XCTUnwrap(fixture.pairing.payload(host: "127.0.0.1", port: fixture.serverPort, appPort: fixture.appPort, name: "Test host"))
    }

    private func pairedPeer(_ fixture: Fixture, storage: TunnelSecretStorage = InMemoryTunnelStorage()) async throws -> SCWPeerConnection {
        try await SCWPeerConnection.pair(try payload(fixture), storage: storage)
    }

    /// A raw client of a device registered directly, for tests below the `SCWPeerConnection` API.
    private func pairedRawClient(_ fixture: Fixture) async throws -> (client: SSHTunnelClient, key: Curve25519.Signing.PrivateKey) {
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertTrue(fixture.pairing.attemptPairing(device: NIOSSHPrivateKey(ed25519Key: key).publicKey, token: fixture.pairing.openPairing()))
        let client = SSHTunnelClient()
        let hostKey = fixture.pairing.hostPublicKey
        try await client.connect(host: "127.0.0.1", port: fixture.serverPort, key: key, credential: .key) { $0 == hostKey }
        return (client, key)
    }

    private func get(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Tunnel

    func testGetAndPostThroughThePairedPeerWithAPlainURLSession() async throws {
        let fixture = try await makeFixture()
        let peer = try await pairedPeer(fixture)
        let base = try await peer.start()

        let pong = try await get(base.appendingPathComponent("ping"))
        XCTAssertEqual(pong, "pong")

        var post = URLRequest(url: base.appendingPathComponent("echo"))
        post.httpMethod = "POST"
        post.httpBody = Data(repeating: 0x61, count: 200_000) // larger than one SSH packet
        let (echo, _) = try await URLSession(configuration: .ephemeral).data(for: post)
        XCTAssertEqual(echo.count, 200_000)
        await peer.stop()
    }

    func testWebSocketWorksThroughTheTunnel() async throws {
        let fixture = try await makeFixture()
        let peer = try await pairedPeer(fixture)
        let base = try await peer.start()
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(base.port ?? 0)/ws-echo")!)
        task.resume()
        try await task.send(.string("hi"))
        guard case .string(let reply) = try await task.receive() else { return XCTFail("expected text") }
        XCTAssertEqual(reply, "echo: hi")
        task.cancel(with: .normalClosure, reason: nil)
        await peer.stop()
    }

    func testHundredConcurrentRequestsAllSucceed() async throws {
        let fixture = try await makeFixture()
        let peer = try await pairedPeer(fixture)
        let url = try await peer.start().appendingPathComponent("ping")
        let session = URLSession(configuration: .ephemeral)

        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    guard let (data, _) = try? await session.data(from: url) else { return false }
                    return String(decoding: data, as: UTF8.self) == "pong"
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        XCTAssertEqual(successes, 100)
        await peer.stop()
    }

    /// A real listener on the forbidden port: if the tunnel connected there, `accepted` would not stay zero.
    func testDestinationOutsideTheAllowListIsRefusedAndNeverContacted() async throws {
        let fixture = try await makeFixture()
        let (client, _) = try await pairedRawClient(fixture)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let accepted = NIOLockedValueBox(0)
        let decoy = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in accepted.withLockedValue { $0 += 1 }; return channel.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).get()
        let decoyPort = try XCTUnwrap(decoy.localAddress?.port)

        let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        for (host, port) in [("127.0.0.1", decoyPort), ("localhost", decoyPort), ("localhost", fixture.appPort), ("::1", fixture.appPort)] {
            do {
                _ = try await client.openForwardedChannel(toHost: host, port: port, originator: origin) { $0.eventLoop.makeSucceededVoidFuture() }
                XCTFail("\(host):\(port) must be refused")
            } catch {
                XCTAssertNotNil(error)
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(accepted.withLockedValue { $0 }, 0)
        try await decoy.close()
        await client.close()
    }

    func testOfflineHostAndDroppedTunnelFailWithoutCrashing() async throws {
        let offline = SSHTunnelClient()
        do {
            try await offline.connect(host: "127.0.0.1", port: 1, key: Curve25519.Signing.PrivateKey(), credential: .key) { _ in true }
            XCTFail("nothing listens on port 1")
        } catch {
            XCTAssertNotNil(error)
        }
        await offline.close()

        let fixture = try await makeFixture()
        let (connected, _) = try await pairedRawClient(fixture)
        await fixture.server.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        do {
            _ = try await connected.openForwardedChannel(toHost: "127.0.0.1", port: fixture.appPort, originator: origin) { $0.eventLoop.makeSucceededVoidFuture() }
            XCTFail("the tunnel is down")
        } catch {
            XCTAssertNotNil(error)
        }
        await connected.close()
    }

    func testSilentSocketsAreClosedAndConnectionsAreCapped() async throws {
        let fixture = try await makeFixture(handshakeTimeout: .milliseconds(300), maxConnections: 1)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let first = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: fixture.serverPort).get()
        // Over the cap: the second socket is closed at once, even though the first is still silent.
        let second = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: fixture.serverPort).get()
        try await second.closeFuture.get()
        // The silent first socket is closed by the handshake deadline.
        try await first.closeFuture.get()
    }

    /// The handshake deadline must stop applying once the peer has authenticated.
    func testAuthenticatedConnectionOutlivesTheHandshakeTimeout() async throws {
        let fixture = try await makeFixture(handshakeTimeout: .milliseconds(800))
        let peer = try await pairedPeer(fixture)
        let base = try await peer.start()

        try await Task.sleep(nanoseconds: 2_000_000_000)
        let pong = try await get(base.appendingPathComponent("ping"))
        XCTAssertEqual(pong, "pong")
        await peer.stop()
    }

    // MARK: - Pairing and revocation

    func testPairedDeviceReconnectsAfterAnAppRelaunch() async throws {
        let fixture = try await makeFixture()
        let clientStorage = InMemoryTunnelStorage()
        let peer = try await pairedPeer(fixture, storage: clientStorage)
        XCTAssertEqual(peer.name, "Test host")

        // A new object built from what the device stored (an app relaunch) still connects, with the key alone.
        let relaunched = try SCWPeerConnection(hostFingerprint: peer.hostFingerprint, storage: clientStorage)
        let pong = try await get(try await relaunched.start().appendingPathComponent("ping"))
        XCTAssertEqual(pong, "pong")
        await relaunched.stop()

        XCTAssertEqual(fixture.pairing.devices.count, 1)
        XCTAssertFalse(fixture.pairing.isPairingOpen) // no session stays open after a pairing
    }

    func testWrongReusedAndClosedTokensAndWrongHostFingerprintAreRefused() async throws {
        let fixture = try await makeFixture()
        let good = try payload(fixture)

        let wrongToken = try XCTUnwrap(PairingPayload(host: good.host, port: good.port, appPort: good.appPort, token: "wrong", hostKeyFingerprint: good.hostKeyFingerprint))
        await assertPairingFails(wrongToken, .authenticationRefused)

        let wrongHost = try XCTUnwrap(PairingPayload(host: good.host, port: good.port, appPort: good.appPort, token: good.token, hostKeyFingerprint: "SHA256:AAAA"))
        await assertPairingFails(wrongHost, .untrustedHostKey)
        XCTAssertTrue(fixture.pairing.devices.isEmpty)

        _ = try await SCWPeerConnection.pair(good, storage: InMemoryTunnelStorage()) // the real token still works once...
        await assertPairingFails(good, .authenticationRefused) // ...and is then dead, with the session closed
        XCTAssertEqual(fixture.pairing.devices.count, 1)
    }

    private func assertPairingFails(_ payload: PairingPayload, _ expected: TunnelError, line: UInt = #line) async {
        do {
            _ = try await SCWPeerConnection.pair(payload, storage: InMemoryTunnelStorage())
            XCTFail("pairing must fail", line: line)
        } catch {
            XCTAssertEqual(error as? TunnelError, expected, line: line)
        }
    }

    func testUnpairedKeyIsRefusedEvenWhilePairingIsOpen() async throws {
        let fixture = try await makeFixture()
        fixture.pairing.openPairing()
        let stranger = SSHTunnelClient()
        let hostKey = fixture.pairing.hostPublicKey
        do {
            try await stranger.connect(host: "127.0.0.1", port: fixture.serverPort, key: Curve25519.Signing.PrivateKey(), credential: .key) { $0 == hostKey }
            XCTFail("a key that was never paired must not connect")
        } catch {
            XCTAssertEqual(error as? TunnelError, .authenticationRefused)
        }
        await stranger.close()
    }

    func testRevokingADeviceClosesItsLiveConnectionAndBlocksReconnecting() async throws {
        let fixture = try await makeFixture()
        let peer = try await pairedPeer(fixture)
        let base = try await peer.start()
        let pong = try await get(base.appendingPathComponent("ping"))
        XCTAssertEqual(pong, "pong")

        let device = try XCTUnwrap(fixture.pairing.devices.first)
        XCTAssertTrue(try fixture.pairing.revoke(deviceID: device.id))
        try await Task.sleep(nanoseconds: 300_000_000)

        // The open tunnel is gone: a request through the old loopback endpoint fails.
        do {
            _ = try await URLSession(configuration: .ephemeral).data(from: base.appendingPathComponent("ping"))
            XCTFail("the revoked device's connection must be closed")
        } catch {
            XCTAssertNotNil(error)
        }
        // And it cannot come back.
        do {
            _ = try await peer.start()
            XCTFail("a revoked device must not reconnect")
        } catch {
            XCTAssertEqual(error as? TunnelError, .authenticationRefused)
        }
        await peer.stop()
    }
}
