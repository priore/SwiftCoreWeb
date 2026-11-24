// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// A request already encoded for the wire (authentication included), with the id its answer will carry.
struct STUNRequest: Sendable {
    let transactionID: [UInt8]
    let bytes: Data
    /// When set, a success answer must carry a valid MESSAGE-INTEGRITY made with this key.
    var integrityKey: [UInt8]? = nil
}

/// The TCP connection to a TURN server that carries requests and answers, and announces devices that connect to the
/// relayed address (a ConnectionAttempt indication, RFC 6062 §4.4).
final class TURNControlConnection: Sendable {
    let channel: Channel
    let attempts: AsyncStream<TURNAllocation.Attempt>
    private let router: Router

    private init(channel: Channel, router: Router, attempts: AsyncStream<TURNAllocation.Attempt>) {
        self.channel = channel
        self.router = router
        self.attempts = attempts
    }

    static func connect(host: String, port: Int, group: EventLoopGroup) async throws -> TURNControlConnection {
        let (attempts, continuation) = AsyncStream<TURNAllocation.Attempt>.makeStream()
        let router = Router(attempts: continuation)
        let routerBox = UncheckedSendableBox(router)
        let channel = try await ClientBootstrap(group: group.next())
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(routerBox.value) } }
            .connect(host: host, port: port).get()
        return TURNControlConnection(channel: channel, router: router, attempts: attempts)
    }

    /// Sends `request` and waits for the answer with the same transaction id.
    func send(_ request: STUNRequest, timeout: TimeAmount) async throws -> STUNMessage {
        let promise = channel.eventLoop.makePromise(of: STUNMessage.self)
        let router = router
        // Registered on the event loop before the bytes leave, so the answer cannot overtake the registration.
        try await channel.eventLoop.submit { router.expect(request.transactionID, promise, key: request.integrityKey) }.get()
        let deadline = channel.eventLoop.scheduleTask(in: timeout) { router.fail(request.transactionID, TURNAllocation.Failure.timedOut) }
        defer { deadline.cancel() }
        var buffer = channel.allocator.buffer(capacity: request.bytes.count)
        buffer.writeBytes(request.bytes)
        do { try await channel.writeAndFlush(buffer).get() } catch {
            channel.eventLoop.execute { router.fail(request.transactionID, error) }
            throw error
        }
        return try await promise.futureResult.get()
    }

    func close() async { try? await channel.close() }

    /// Event-loop state: the requests waiting for an answer.
    private final class Router: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private var framing = STUNFraming()
        private var waiting: [[UInt8]: (promise: EventLoopPromise<STUNMessage>, key: [UInt8]?)] = [:]
        private let attempts: AsyncStream<TURNAllocation.Attempt>.Continuation

        init(attempts: AsyncStream<TURNAllocation.Attempt>.Continuation) { self.attempts = attempts }

        func expect(_ id: [UInt8], _ promise: EventLoopPromise<STUNMessage>, key: [UInt8]?) { waiting[id] = (promise, key) }

        func fail(_ id: [UInt8], _ error: Error) { waiting.removeValue(forKey: id)?.promise.fail(error) }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            framing.append(&bytes)
            while let raw = framing.nextMessage() {
                guard let (message, integrityOffset) = try? STUNMessage.decode(raw) else { continue }
                if message.messageClass == .indication {
                    guard message.method == STUNMessage.Method.connectionAttempt,
                          let id = message.attribute(STUNMessage.AttributeType.connectionID),
                          let peer = message.attribute(STUNMessage.AttributeType.xorPeerAddress).flatMap({ STUNMessage.decodeXorAddress($0, transactionID: message.transactionID) })
                    else { continue }
                    attempts.yield(TURNAllocation.Attempt(connectionID: id, peer: peer))
                } else {
                    guard let entry = waiting.removeValue(forKey: message.transactionID) else { continue }
                    if message.messageClass == .success, let key = entry.key,
                       !(integrityOffset.map { STUNMessage.integrityIsValid(raw, integrityOffset: $0, key: key) } ?? false) {
                        entry.promise.fail(TURNAllocation.Failure.unexpectedResponse) // not made by whoever holds the credentials
                    } else {
                        entry.promise.succeed(message)
                    }
                }
            }
        }

        func channelInactive(context: ChannelHandlerContext) { finish(TURNAllocation.Failure.closed) }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            finish(error)
            context.close(promise: nil)
        }

        private func finish(_ error: Error) {
            attempts.finish()
            let all = waiting
            waiting = [:]
            all.values.forEach { $0.promise.fail(error) }
        }
    }
}
