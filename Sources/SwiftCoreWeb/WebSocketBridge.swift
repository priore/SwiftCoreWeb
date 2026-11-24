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
                var buffer = channel.allocator.buffer(capacity: 2)
                buffer.write(webSocketErrorCode: code)
                try? await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)).get()
                try? await channel.close()
            }
        ))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard !closing else { return } // nothing is answered after a close frame (§5.5.1)
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
            guard frame.unmaskedData.readableBytes != 1 else { return fail(context, .protocolError) } // §5.5.1: empty, or a code
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
            if case .dropped = continuation.yield(message) { fail(context, .policyViolation) }
        } else if earlyMessages < Self.maxQueuedMessages, earlyBytes + bytes.count <= Self.maxEarlyBytes {
            earlyMessages += 1
            earlyBytes += bytes.count
            continuation.yield(message)
        }
    }

    /// Closes with `code` after telling the peer why (RFC 6455 §7.4).
    private func fail(_ context: ChannelHandlerContext, _ code: WebSocketErrorCode) {
        closing = true
        continuation.finish()
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
