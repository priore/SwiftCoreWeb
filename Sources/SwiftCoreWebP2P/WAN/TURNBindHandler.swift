// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOCore

/// The data connection of RFC 6062 §4.3: it starts as a STUN exchange (ConnectionBind) and, once the server accepts, carries
/// the device's bytes as they are. Bytes that arrive before the caller has installed the handlers that will read them are
/// held and delivered by `activate`, so none is lost.
final class TURNBindHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private var framing = STUNFraming()
    private var answer: EventLoopPromise<STUNMessage>?
    private var expected: [UInt8] = []
    private var integrityKey: [UInt8]?
    private var bound = false
    private var active = false
    private var held = ByteBuffer()
    private var context: ChannelHandlerContext?

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    /// Sends the ConnectionBind request and waits for its answer.
    func send(_ request: STUNRequest, on channel: Channel, timeout: TimeAmount) async throws -> STUNMessage {
        let promise = channel.eventLoop.makePromise(of: STUNMessage.self)
        try await channel.eventLoop.submit {
            self.answer = promise
            self.expected = request.transactionID
            self.integrityKey = request.integrityKey
        }.get()
        let deadline = channel.eventLoop.scheduleTask(in: timeout) { promise.fail(TURNAllocation.Failure.timedOut) }
        defer { deadline.cancel() }
        var buffer = channel.allocator.buffer(capacity: request.bytes.count)
        buffer.writeBytes(request.bytes)
        try await channel.writeAndFlush(buffer).get()
        return try await promise.futureResult.get()
    }

    /// From now on bytes are delivered down the pipeline, those already held first.
    func activate(on channel: Channel) {
        channel.eventLoop.execute {
            self.active = true
            if self.held.readableBytes > 0, let context = self.context {
                let bytes = self.held
                self.held = ByteBuffer()
                context.fireChannelRead(self.wrapInboundOut(bytes))
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        if bound {
            if active { context.fireChannelRead(wrapInboundOut(bytes)) } else { held.writeBuffer(&bytes) }
            return
        }
        framing.append(&bytes)
        guard let raw = framing.nextMessage() else { return }
        guard let (message, integrityOffset) = try? STUNMessage.decode(raw), message.transactionID == expected,
              message.messageClass != .success || integrityKey == nil
                || (integrityOffset.map { STUNMessage.integrityIsValid(raw, integrityOffset: $0, key: integrityKey ?? []) } ?? false) else {
            answer?.fail(TURNAllocation.Failure.unexpectedResponse)
            context.close(promise: nil)
            return
        }
        bound = message.messageClass == .success
        var rest = framing.takeRemainder() // what followed the answer already belongs to the device
        held.writeBuffer(&rest)
        answer?.succeed(message)
    }

    func channelInactive(context: ChannelHandlerContext) {
        answer?.fail(TURNAllocation.Failure.closed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        answer?.fail(error)
        context.fireErrorCaught(error)
    }
}
