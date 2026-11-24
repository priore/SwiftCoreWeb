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
@testable import SwiftCoreWebP2P

/// The host's half of hole punching: it connects out to a device's announced address from the tunnel's own port, and speaks
/// SSH (as the server) on the connection that results.
final class HostPunchTests: XCTestCase {
    private final class Peer: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let banner = NIOLockedValueBox("")
        let source = NIOLockedValueBox<Int?>(nil)
        func channelActive(context: ChannelHandlerContext) { source.withLockedValue { $0 = context.remoteAddress?.port } }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            banner.withLockedValue { $0 += bytes.readString(length: bytes.readableBytes) ?? "" }
        }
    }

    func testTheHostConnectsOutFromItsTunnelPortAndServesSSH() async throws {
        let pairing = try PairingManager(storage: InMemoryTunnelStorage())
        let server = SSHTunnelServer(pairing: pairing, allowList: TunnelAllowList(port: 8080))
        let tunnelPort = try await server.start(host: "127.0.0.1", port: 0)
        addTeardownBlock { await server.stop() }

        // The "device": a socket that accepts what the host opens towards it.
        let peer = Peer()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(peer) }
            .bind(host: "127.0.0.1", port: 0).get()
        let devicePort = try XCTUnwrap(listener.localAddress?.port)

        let publisher = RemoteAccessPublisher(
            remote: P2PRemoteAccess(rendezvous: URL(string: "http://127.0.0.1:1")!, relay: .init(host: "127.0.0.1", port: 1, username: "u", password: "p")),
            pairing: pairing, server: server
        )
        publisher.punch(to: .init(kind: "direct", host: "127.0.0.1", port: devicePort), from: tunnelPort, device: "device-1")
        for _ in 0..<60 where !peer.banner.withLockedValue({ $0 }).hasPrefix("SSH-2.0") { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(peer.banner.withLockedValue { $0 }.hasPrefix("SSH-2.0"), "the host speaks SSH as the server on the connection it opened")
        XCTAssertEqual(peer.source.withLockedValue { $0 }, tunnelPort, "it left from the tunnel's own port")

        await publisher.stop()
        try await listener.close()
    }
}
