// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOWebSocket

/// Carries WebSocket frames between an upgraded channel and a `WebSocket`.
///
/// The connection's pipeline already holds the `NIOAsyncChannel` that served the HTTP side, typed for HTTP parts, so
/// the frame codec and this handler are placed in front of it: frames stop here and never reach a handler that would
/// not understand them. Pings are answered and a close frame is echoed, as RFC 6455 asks.
final class WebSocketBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    /// A frame larger than this is refused with 1009.
    static let maxFrameSize = 1 << 20
    /// A message (all its fragments) larger than this is refused with 1009.
    static let maxMessageSize = 16 << 20
    /// Messages waiting for a handler that reads slowly; past this the connection is closed with 1008.
    static let maxQueuedMessages = 256

    private let continuation: AsyncThrowingStream<WebSocketMessage, Error>.Continuation
    private let stream: AsyncThrowingStream<WebSocketMessage, Error>
    /// A client may send right after the 101, before the handler has asked for `messages()`: those frames are kept, up to
    /// `maxEarlyBytes` / `maxQueuedMessages`, and dropped beyond that, so a handler that never reads (a broadcaster) does
    /// not make the connection pile them up. Touched on the event loop and by the handler's task, hence the lock.
    static let maxEarlyBytes = 1 << 20
    private let hasConsumer = NIOLockedValueBox(false)
    // Event loop only.
    private var earlyMessages = 0
    private var earlyBytes = 0
    private var closing = false
    /// Set (on the event loop) once this side has sent its own close frame: the peer's reply then ends the connection.
    private var sentClose = false
    let closeReplyTimeout: TimeAmount = .seconds(5)
    private var fragments: ByteBuffer?
    private var fragmentIsText = false

    init() {
        (stream, continuation) = AsyncThrowingStream<WebSocketMessage, Error>.makeStream(bufferingPolicy: .bufferingOldest(Self.maxQueuedMessages))
    }

    var messages: AsyncThrowingStream<WebSocketMessage, Error> {
        hasConsumer.withLockedValue { $0 = true }
        return stream
    }

    /// Answers the upgrade with `response` (through the HTTP encoder), drops the HTTP handlers named in `httpHandlers`, and
    /// puts the frame codec and the bridge in front of what is left. All of it happens in one event-loop turn: the client may
    /// send its first frame the moment it sees the 101, and no byte may be read between the HTTP decoder going and the
    /// frame decoder arriving.
    static func upgrade(_ channel: Channel, response: HTTPResponseHead, removing httpHandlers: [String]) async throws -> WebSocket {
        let bridge = WebSocketBridge()
        try await channel.eventLoop.submit {
            let pipeline = channel.pipeline.syncOperations
            channel.write(HTTPServerResponsePart.head(response), promise: nil)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            for name in httpHandlers { _ = pipeline.removeHandler(name: name) }
            // Added at the front in reverse, so the order is: decoder, encoder, bridge, then what was there.
            try pipeline.addHandler(bridge, position: .first)
            try pipeline.addHandler(WebSocketFrameEncoder(), position: .first)
            try pipeline.addHandler(ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: Self.maxFrameSize)), position: .first)
        }.get()
        return WebSocket(transport: WebSocket.Transport(
            messages: { bridge.messages },
            send: { message in
                let frame: WebSocketFrame
                switch message {
                case .text(let text):
                    var buffer = channel.allocator.buffer(capacity: text.utf8.count)
                    buffer.writeString(text)
                    frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
                case .binary(let data):
                    var buffer = channel.allocator.buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
                }
                try await channel.writeAndFlush(frame).get()
            },
            close: { code in
                var closeBuffer = channel.allocator.buffer(capacity: 2)
                closeBuffer.write(webSocketErrorCode: code)
                let buffer = closeBuffer
                // Say goodbye, then give the peer a moment to answer with its own close frame before dropping the TCP
                // connection: closing at once can reset a peer that is still sending.
                let sent = try? await channel.eventLoop.submit {
                    // A close frame is already on its way (the peer's echo, or a protocol failure): never send a second one.
                    guard !bridge.isClosing else { return channel.eventLoop.makeSucceededVoidFuture() }
                    bridge.markCloseSent()
                    return channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer))
                }.flatMap { $0 }.get()
                if sent != nil {
                    let timeout = channel.eventLoop.scheduleTask(in: bridge.closeReplyTimeout) { channel.close(promise: nil) }
                    try? await channel.closeFuture.get()
                    timeout.cancel()
                }
                try? await channel.close()
            }
        ))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if closing {
            // Nothing is answered after a close frame (§5.5.1); the peer's reply to ours completes the handshake (§7.1.2).
            if sentClose, frame.opcode == .connectionClose { context.close(promise: nil) }
            return
        }
        guard !frame.rsv1, !frame.rsv2, !frame.rsv3 else { return fail(context, .protocolError) } // no extension negotiated
        // RFC 6455 §5.1: a client must mask every frame.
        guard frame.maskKey != nil else { return fail(context, .protocolError) }
        switch frame.opcode {
        case .text, .binary:
            guard fragments == nil else { return fail(context, .protocolError) } // a new message inside an unfinished one
            if frame.fin {
                deliver(frame.unmaskedData, isText: frame.opcode == .text, context: context)
            } else {
                fragments = frame.unmaskedData
                fragmentIsText = frame.opcode == .text
            }
        case .continuation:
            guard var pending = fragments else { return fail(context, .protocolError) }
            var more = frame.unmaskedData
            let limit = hasConsumer.withLockedValue({ $0 }) ? Self.maxMessageSize : Self.maxEarlyBytes
            guard pending.readableBytes + more.readableBytes <= limit else { return fail(context, .messageTooLarge) }
            pending.writeBuffer(&more)
            if frame.fin {
                fragments = nil
                deliver(pending, isText: fragmentIsText, context: context)
            } else {
                fragments = pending
            }
        case .ping:
            // A pong is optional when the peer is not reading: do not let a ping flood fill the outbound buffer.
            guard context.channel.isWritable else { return }
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            if let rejection = Self.closeRejection(frame.unmaskedData) { return fail(context, rejection) }
            closing = true
            continuation.finish()
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)))
                .whenComplete { _ in context.close(promise: nil) }
        case .pong:
            break
        default:
            fail(context, .protocolError) // reserved opcode
        }
    }

    private func deliver(_ payload: ByteBuffer, isText: Bool, context: ChannelHandlerContext) {
        guard payload.readableBytes <= Self.maxMessageSize else { return fail(context, .messageTooLarge) }
        var buffer = payload
        let bytes = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        let message: WebSocketMessage
        if isText {
            guard let text = String(data: bytes, encoding: .utf8) else { return fail(context, .dataInconsistentWithMessage) } // §8.1
            message = .text(text)
        } else {
            message = .binary(bytes)
        }
        if hasConsumer.withLockedValue({ $0 }) {
            if case .dropped = continuation.yield(message) { fail(context, .policyViolation, throwing: WebSocketError.slowConsumer) }
        } else if earlyMessages < Self.maxQueuedMessages / 2, earlyBytes + bytes.count <= Self.maxEarlyBytes {
            earlyMessages += 1
            earlyBytes += bytes.count
            continuation.yield(message)
        }
    }

    /// RFC 6455 §5.5.1 / §7.4: a close payload is empty, or a valid status code followed by UTF-8 text.
    static func closeRejection(_ payload: ByteBuffer) -> WebSocketErrorCode? {
        var buffer = payload
        if buffer.readableBytes == 0 { return nil }
        guard buffer.readableBytes >= 2, let code = buffer.readInteger(as: UInt16.self) else { return .protocolError }
        switch code {
        case 1000...1003, 1007...1014, 3000...4999: break
        default: return .protocolError
        }
        let reason = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        return String(data: reason, encoding: .utf8) == nil ? .dataInconsistentWithMessage : nil
    }

    /// Event loop only.
    var isClosing: Bool { closing }

    /// Called from the event loop when this side sends its own close frame.
    func markCloseSent() {
        closing = true
        sentClose = true
        continuation.finish()
    }

    /// Closes with `code` after telling the peer why (RFC 6455 §7.4).
    private func fail(_ context: ChannelHandlerContext, _ code: WebSocketErrorCode, throwing error: Error? = nil) {
        closing = true
        continuation.finish(throwing: error)
        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
        context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)))
            .whenComplete { _ in context.close(promise: nil) }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Reads must not depend on the HTTP-side async handler further down the pipeline: ask for them from here.
        context.read()
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        if let error = error as? NIOWebSocketError {
            // Only a length the decoder refuses is "too large"; a fragmented or oversized control frame is a protocol error.
            if case .invalidFrameLength = error { fail(context, .messageTooLarge) } else { fail(context, .protocolError) }
        } else {
            context.close(promise: nil)
        }
    }
}
