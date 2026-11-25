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

/// The client against a minimal STUN server of our own on the loopback; the real-world behaviour of public servers is not covered.
final class STUNClientTests: XCTestCase {
    private enum Mode { case answer, error401, silent, wrongTransaction }

    /// Answers a Binding request with the address the connection came from, or as `mode` says.
    private func startServer(_ mode: Mode, group: EventLoopGroup) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(StubServer(mode: mode))
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    private final class StubServer: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let mode: Mode
        init(mode: Mode) { self.mode = mode }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            guard let bytes = buffer.readBytes(length: buffer.readableBytes), let (request, _) = try? STUNMessage.decode(Data(bytes)) else { return }
            let reply: STUNMessage
            switch mode {
            case .silent:
                return
            case .error401:
                reply = STUNMessage(method: request.method, messageClass: .error, transactionID: request.transactionID,
                                    attributes: [.init(type: STUNMessage.AttributeType.errorCode, value: [0, 0, 4, 1] + Array("Unauthorized".utf8))])
            case .answer, .wrongTransaction:
                let remote = context.remoteAddress
                let attribute = STUNMessage.xorAddressAttribute(host: remote?.ipAddress ?? "0.0.0.0", port: remote?.port ?? 0, transactionID: request.transactionID)
                let id = mode == .wrongTransaction ? [UInt8](repeating: 9, count: 12) : request.transactionID
                reply = STUNMessage(method: request.method, messageClass: .success, transactionID: id, attributes: attribute.map { [$0] } ?? [])
            }
            var out = context.channel.allocator.buffer(capacity: 64)
            out.writeBytes(reply.encoded(fingerprint: true))
            context.writeAndFlush(NIOAny(out), promise: nil)
        }
    }

    func testReportsTheAddressAndPortTheServerSaw() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try await startServer(.answer, group: group)
        addTeardownBlock { try? await server.close() }

        let localPort = Int.random(in: 40_000..<60_000)
        let address = try await STUNClient.reflexiveAddress(server: "127.0.0.1", port: try XCTUnwrap(server.localAddress?.port), localPort: localPort, group: group)
        XCTAssertEqual(address.host, "127.0.0.1")
        XCTAssertEqual(address.port, localPort, "the server saw the connection leave from the requested local port")
    }

    func testFailuresAreTyped() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        for (mode, expected) in [(Mode.error401, STUNClient.Failure.serverError(code: 401)), (.silent, .timedOut), (.wrongTransaction, .unexpectedResponse)] {
            let server = try await startServer(mode, group: group)
            addTeardownBlock { try? await server.close() }
            do {
                _ = try await STUNClient.reflexiveAddress(server: "127.0.0.1", port: try XCTUnwrap(server.localAddress?.port), timeout: .milliseconds(400), group: group)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? STUNClient.Failure, expected)
            }
        }
    }
}
