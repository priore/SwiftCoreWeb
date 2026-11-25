// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import NIOCore
import NIOPosix
@testable import SwiftCoreWebP2P

final class TCPKeepAliveTests: XCTestCase {
    func testAConnectionNoticesADeadPeerInAboutAMinute() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let server = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let channel = try await ClientBootstrap(group: group).channelInitializer { TCPKeepAlive.apply(to: $0) }
            .connect(to: try XCTUnwrap(server.localAddress)).get()
        let on = try await channel.getOption(ChannelOptions.socketOption(.so_keepalive)).get()
        XCTAssertNotEqual(on, 0)
        #if canImport(Darwin)
        let idle = try await channel.getOption(ChannelOptions.Types.SocketOption(level: NIOBSDSocket.OptionLevel(rawValue: IPPROTO_TCP), name: NIOBSDSocket.Option(rawValue: TCP_KEEPALIVE))).get()
        XCTAssertEqual(idle, CInt(TCPKeepAlive.idleSeconds))
        #endif
        try await channel.close()
        try await server.close()
    }
}
