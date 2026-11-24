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

/// Against a real coturn. Start one before running (these tests skip when nothing listens on port 34780):
///
///     turnserver --no-tls --listening-port 34780 -L 127.0.0.1 -E 127.0.0.1 --min-port 50000 --max-port 50100 \\
///       -r scw.test -a -u scw:secret --allow-loopback-peers --simple-log
final class TURNAllocationTests: XCTestCase {
    private let credentials = TURNAllocation.Credentials(username: "scw", password: "secret")

    override func setUp() async throws {
        do {
            let probe = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connect(host: "127.0.0.1", port: 34780).get()
            try await probe.close()
        } catch {
            throw XCTSkip("no TURN server on 127.0.0.1:34780 (see the header of this file)")
        }
    }

    private final class Echo: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.writeAndFlush(data, promise: nil) }
    }

    private final class Collector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let received = NIOLockedValueBox(ByteBuffer())
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            received.withLockedValue { $0.writeBuffer(&bytes) }
        }
    }

    func testADeviceReachesTheHostThroughTheRelay() async throws {
        let allocation = try await TURNAllocation.allocate(server: "127.0.0.1", port: 34780, credentials: credentials)
        addTeardownBlock { await allocation.close() }
        XCTAssertGreaterThan(allocation.relayedPort, 0)
        try await allocation.permit(ip: "127.0.0.1")

        // The host side: every announced device gets an echo on its bound connection.
        let serving = Task {
            for await attempt in allocation.attempts {
                try? await allocation.accept(attempt) { $0.pipeline.addHandler(Echo()) }
            }
        }
        addTeardownBlock { serving.cancel() }

        // The device side: a plain TCP connection to the relayed address; it needs nothing of TURN.
        let collector = Collector()
        let device = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { $0.pipeline.addHandler(collector) }
            .connect(host: allocation.relayedHost, port: allocation.relayedPort).get()
        addTeardownBlock { try? await device.close() }
        try await device.writeAndFlush(device.allocator.buffer(string: "hello through the relay")).get()
        for _ in 0..<50 where collector.received.withLockedValue({ $0.readableBytes }) < 23 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(collector.received.withLockedValue { String(buffer: $0) }, "hello through the relay")
    }

    func testBytesSentBeforeTheBindingFinishesAreNotLost() async throws {
        let allocation = try await TURNAllocation.allocate(server: "127.0.0.1", port: 34780, credentials: credentials)
        addTeardownBlock { await allocation.close() }
        try await allocation.permit(ip: "127.0.0.1")

        let collector = Collector()
        let device = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { $0.pipeline.addHandler(collector) }
            .connect(host: allocation.relayedHost, port: allocation.relayedPort).get()
        addTeardownBlock { try? await device.close() }
        // The device speaks first, as an SSH client does with its banner, before the host has bound anything.
        try await device.writeAndFlush(device.allocator.buffer(string: "first words")).get()

        var iterator = allocation.attempts.makeAsyncIterator()
        let next = await iterator.next()
        let attempt = try XCTUnwrap(next)
        try await allocation.accept(attempt) { $0.pipeline.addHandler(Echo()) }
        for _ in 0..<50 where collector.received.withLockedValue({ $0.readableBytes }) < 11 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(collector.received.withLockedValue { String(buffer: $0) }, "first words")
    }

    func testWrongPasswordIsRefused() async throws {
        do {
            _ = try await TURNAllocation.allocate(server: "127.0.0.1", port: 34780, credentials: .init(username: "scw", password: "wrong"))
            XCTFail("must be refused")
        } catch {
            guard case TURNAllocation.Failure.refused = error else { return XCTFail("unexpected \(error)") }
        }
    }
}
