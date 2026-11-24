// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SwiftCoreWeb
@testable import SwiftCoreWebP2P

/// The app must see each paired device as its own client, not as `127.0.0.1`, and long-lived routes must work through the tunnel.
final class PeerIdentityTests: XCTestCase {
    private struct Fixture {
        let app: WebApplication
        let host: P2PHost
        let appPort: Int
    }

    private func makeFixture(rateLimit: Bool = false) async throws -> Fixture {
        let appPort = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(appPort)
        if rateLimit { builder.rateLimit { $0.capacity = 3; $0.refillPerSecond = 0.001 } }
        let host = try builder.useP2P(storage: InMemoryTunnelStorage())
        let app = builder.build()
        app.mapGet("/whoami") { ctx in ctx.request.remoteAddress ?? "none" }
        app.mapSse("/events") { writer in
            for index in 1...3 { try await writer.send("tick \(index)") }
        }
        addTeardownBlock { try? await app.stopAsync() }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where host.tunnelPort == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNotNil(host.tunnelPort)
        return Fixture(app: app, host: host, appPort: appPort)
    }

    private func pair(_ fixture: Fixture) async throws -> (peer: SCWPeerConnection, base: URL) {
        let payload = try XCTUnwrap(fixture.host.openPairing(host: "127.0.0.1"))
        let peer = try await SCWPeerConnection.pair(payload, storage: InMemoryTunnelStorage())
        return (peer, try await peer.start())
    }

    private func status(_ url: URL) async throws -> Int {
        let (_, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    func testTheAppSeesTheDeviceNotLoopback() async throws {
        let fixture = try await makeFixture()
        let (peer, base) = try await pair(fixture)
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: base.appendingPathComponent("whoami"))
        let seen = String(decoding: data, as: UTF8.self)
        let device = try XCTUnwrap(fixture.host.pairing?.devices.first)
        XCTAssertEqual(seen, "p2p:" + device.id)
        await peer.stop()
    }

    func testRateLimitIsPerDevice() async throws {
        let fixture = try await makeFixture(rateLimit: true)
        let first = try await pair(fixture)
        let second = try await pair(fixture)
        let firstURL = first.base.appendingPathComponent("whoami"), secondURL = second.base.appendingPathComponent("whoami")

        var codes: [Int] = []
        for _ in 0..<5 { codes.append((try? await status(firstURL)) ?? -1) } // each request is a new connection: the limit counts connections
        XCTAssertEqual(codes, [200, 200, 200, 429, 429]) // capacity 3 for this device
        let secondCode = (try? await status(secondURL)) ?? -1
        XCTAssertEqual(secondCode, 200) // another device has its own bucket
        await first.peer.stop(); await second.peer.stop()
    }

    func testPeerListenerRefusesMissingOrWrongSecretAndAcceptsALineGluedToTheRequest() async throws {
        let fixture = try await makeFixture()
        let peer = try XCTUnwrap(fixture.host.tunnel?.peer)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let request = "GET /whoami HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"

        func exchange(_ payload: String) async throws -> String {
            let received = NIOLockedValueBox("")
            let channel = try await ClientBootstrap(group: group).channelInitializer { $0.pipeline.addHandler(Collector(received)) }
                .connect(host: "127.0.0.1", port: peer.port).get()
            try await channel.writeAndFlush(channel.allocator.buffer(string: payload))
            // The server may keep the connection open after answering, so read for a moment and then hang up ourselves.
            try await Task.sleep(nanoseconds: 600_000_000)
            try? await channel.close()
            return received.withLockedValue { $0 }
        }

        let noPreamble = try await exchange(request)
        XCTAssertFalse(noPreamble.contains("200 OK"), noPreamble)
        let wrongSecret = try await exchange("SCW-PEER wrong p2p:fake\n" + request)
        XCTAssertFalse(wrongSecret.contains("200 OK"), wrongSecret)
        // The identity line and the request in one write: the bytes after the line must not be lost.
        let glued = try await exchange(peer.preamble(identity: "p2p:glued") + request)
        XCTAssertTrue(glued.contains("200 OK"), glued)
        XCTAssertTrue(glued.hasSuffix("p2p:glued"), glued)
    }

    func testServerSentEventsWorkThroughTheTunnel() async throws {
        let fixture = try await makeFixture()
        let (peer, base) = try await pair(fixture)
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: base.appendingPathComponent("events"))
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("data: tick 1") && body.contains("data: tick 3"), body)
        await peer.stop()
    }
}

private final class Collector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let received: NIOLockedValueBox<String>
    init(_ received: NIOLockedValueBox<String>) { self.received = received }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        received.withLockedValue { $0 += buffer.readString(length: buffer.readableBytes) ?? "" }
    }
}
