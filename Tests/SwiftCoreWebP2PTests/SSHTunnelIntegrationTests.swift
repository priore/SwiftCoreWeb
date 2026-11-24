// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import Crypto
import NIOCore
import NIOSSH
import SwiftCoreWeb
@testable import SwiftCoreWebP2P

/// A real SCW app on the loopback, an SSH tunnel server in front of it, a client and a loopback proxy: a plain
/// `URLSession` talks to the app through the tunnel.
final class SSHTunnelIntegrationTests: XCTestCase {
    private struct Fixture {
        let app: WebApplication
        let appPort: Int
        let server: SSHTunnelServer
        let serverPort: Int
        let clientKey: Curve25519.Signing.PrivateKey
    }

    private func makeFixture(authorize: Bool = true) async throws -> Fixture {
        let appPort = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(appPort)
        let app = builder.build()
        app.mapGet("/ping") { _ in "pong" }
        app.mapPost("/echo") { ctx in String(decoding: ctx.request.body, as: UTF8.self) }
        Task { try await app.runAsync() }
        for _ in 0..<100 where !app.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }

        let clientKey = Curve25519.Signing.PrivateKey()
        let authorizedKey = NIOSSHPrivateKey(ed25519Key: clientKey).publicKey
        let server = SSHTunnelServer(
            hostKey: Curve25519.Signing.PrivateKey(),
            allowList: TunnelAllowList(port: appPort),
            isAuthorized: { authorize && $0 == authorizedKey }
        )
        return Fixture(app: app, appPort: appPort, server: server, serverPort: try await server.start(host: "127.0.0.1"), clientKey: clientKey)
    }

    private func connectedClient(_ fixture: Fixture) async throws -> SSHTunnelClient {
        let client = SSHTunnelClient()
        let hostKey = fixture.server.hostPublicKey
        try await client.connect(host: "127.0.0.1", port: fixture.serverPort, username: "device", key: fixture.clientKey, trustedHostKey: { $0 == hostKey })
        return client
    }

    private func tearDown(_ fixture: Fixture) async {
        await fixture.server.stop()
        try? await fixture.app.stopAsync()
    }

    func testGetAndPostThroughTheTunnelWithAPlainURLSession() async throws {
        let fixture = try await makeFixture()
        let client = try await connectedClient(fixture)
        let proxy = LoopbackProxy(client: client, destination: TunnelAllowList(port: fixture.appPort))
        let proxyPort = try await proxy.start()

        let session = URLSession(configuration: .ephemeral)
        let (pong, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(proxyPort)/ping")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: pong, as: UTF8.self), "pong")

        var post = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/echo")!)
        post.httpMethod = "POST"
        post.httpBody = Data(repeating: 0x61, count: 200_000) // larger than one SSH packet
        let (echo, _) = try await session.data(for: post)
        XCTAssertEqual(echo.count, 200_000)

        await proxy.stop(); await client.close(); await tearDown(fixture)
    }

    func testHundredConcurrentRequestsAllSucceed() async throws {
        let fixture = try await makeFixture()
        let client = try await connectedClient(fixture)
        let proxy = LoopbackProxy(client: client, destination: TunnelAllowList(port: fixture.appPort))
        let url = URL(string: "http://127.0.0.1:\(try await proxy.start())/ping")!
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

        await proxy.stop(); await client.close(); await tearDown(fixture)
    }

    func testDestinationOutsideTheAllowListIsRefused() async throws {
        let fixture = try await makeFixture()
        let client = try await connectedClient(fixture)
        let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        for (host, port) in [("127.0.0.1", fixture.appPort + 1), ("example.com", 80), ("localhost", fixture.appPort)] {
            do {
                _ = try await client.openForwardedChannel(toHost: host, port: port, originator: origin) { $0.eventLoop.makeSucceededVoidFuture() }
                XCTFail("\(host):\(port) must be refused")
            } catch {}
        }
        await client.close(); await tearDown(fixture)
    }

    func testUnauthorizedKeyAndUntrustedHostKeyAreRefused() async throws {
        let fixture = try await makeFixture(authorize: false)
        let hostKey = fixture.server.hostPublicKey

        let refusedKey = SSHTunnelClient()
        do {
            try await refusedKey.connect(host: "127.0.0.1", port: fixture.serverPort, username: "device", key: fixture.clientKey, trustedHostKey: { $0 == hostKey })
            XCTFail("an unauthorized key must not connect")
        } catch {}
        await refusedKey.close()

        let wrongHost = SSHTunnelClient()
        do {
            try await wrongHost.connect(host: "127.0.0.1", port: fixture.serverPort, username: "device", key: fixture.clientKey, trustedHostKey: { _ in false })
            XCTFail("an untrusted host key must not connect")
        } catch {}
        await wrongHost.close()

        await tearDown(fixture)
    }
}
