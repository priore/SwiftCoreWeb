// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOCore
import NIOPosix

/// Asks a STUN server over TCP how this device looks from the outside (RFC 8489, Binding method). It is TCP because the
/// tunnel is TCP: a NAT maps a TCP connection and a UDP flow separately, so an address learned over UDP says nothing about
/// where a TCP connection can be reached.
enum STUNClient {
    enum Failure: Error, Equatable {
        case timedOut
        case closed
        case unexpectedResponse
        case serverError(code: Int)
    }

    /// The address and port the server saw this connection come from. With `localPort`, the connection leaves from that
    /// port (with `SO_REUSEADDR` and `SO_REUSEPORT`, so another socket can use the same port afterwards); the mapping the
    /// server reports is then the one a peer would have to reach.
    static func reflexiveAddress(
        server host: String,
        port: Int,
        localPort: Int? = nil,
        timeout: TimeAmount = .seconds(5),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> (host: String, port: Int) {
        let request = STUNMessage(method: STUNMessage.Method.binding, messageClass: .request)
        let loop = group.next()
        let answer = loop.makePromise(of: STUNMessage.self)

        var bootstrap = ClientBootstrap(group: loop).connectTimeout(.seconds(3)).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(STUNResponseHandler(promise: answer, transactionID: request.transactionID))
            }
        }
        if let localPort {
            bootstrap = bootstrap
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socketOption(.so_reuseport), value: 1)
                .bind(to: try SocketAddress(ipAddress: "0.0.0.0", port: localPort))
        }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            answer.fail(error)
            throw error
        }
        let deadline = loop.scheduleTask(in: timeout) { answer.fail(Failure.timedOut) }
        defer { deadline.cancel() }
        do {
            var buffer = channel.allocator.buffer(capacity: STUNMessage.headerSize)
            buffer.writeBytes(request.encoded())
            try await channel.writeAndFlush(buffer).get()
            let response = try await answer.futureResult.get()
            try? await channel.close()
            if response.messageClass == .error { throw Failure.serverError(code: response.errorCode?.code ?? 0) }
            guard response.messageClass == .success, let address = response.xorMappedAddress else { throw Failure.unexpectedResponse }
            return address
        } catch {
            try? await channel.close()
            throw error
        }
    }
}

/// Collects bytes until one whole STUN message has arrived (the header says how long it is) and hands it over.
private final class STUNResponseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var buffer = ByteBuffer()
    private let promise: EventLoopPromise<STUNMessage>
    private let transactionID: [UInt8]

    init(promise: EventLoopPromise<STUNMessage>, transactionID: [UInt8]) {
        self.promise = promise
        self.transactionID = transactionID
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard buffer.readableBytes >= STUNMessage.headerSize, let length = buffer.getInteger(at: buffer.readerIndex + 2, as: UInt16.self) else { return }
        let total = STUNMessage.headerSize + Int(length)
        guard buffer.readableBytes >= total, let bytes = buffer.readBytes(length: total) else { return }
        do {
            let (message, _) = try STUNMessage.decode(Data(bytes))
            // An answer to another request is not ours (RFC 8489 §6.3.1).
            guard message.transactionID == transactionID else { return promise.fail(STUNClient.Failure.unexpectedResponse) }
            promise.succeed(message)
        } catch {
            promise.fail(STUNClient.Failure.unexpectedResponse)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(STUNClient.Failure.closed)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}
