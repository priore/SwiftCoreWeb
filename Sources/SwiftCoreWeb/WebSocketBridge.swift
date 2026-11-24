// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
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

    private let continuation: AsyncThrowingStream<WebSocketMessage, Error>.Continuation
    let messages: AsyncThrowingStream<WebSocketMessage, Error>

    init() {
        (messages, continuation) = AsyncThrowingStream<WebSocketMessage, Error>.makeStream()
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
            try pipeline.addHandler(ByteToMessageHandler(WebSocketFrameDecoder()), position: .first)
            // The async channel that served the HTTP side may have paused reading; the bridge is now the reader.
            try channel.syncOptions?.setOption(.autoRead, value: true)
            channel.read()
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
        switch frame.opcode {
        case .text:
            var buffer = frame.unmaskedData
            continuation.yield(.text(buffer.readString(length: buffer.readableBytes) ?? ""))
        case .binary:
            var buffer = frame.unmaskedData
            continuation.yield(.binary(Data(buffer.readBytes(length: buffer.readableBytes) ?? [])))
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            continuation.finish()
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)))
                .whenComplete { _ in context.close(promise: nil) }
        default:
            break // pong, and continuation frames (fragmented messages are not reassembled)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}
