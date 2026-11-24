// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOCore
import NIOWebSocket
import NIOConcurrencyHelpers

/// A message received from, or to send to, a WebSocket peer.
public enum WebSocketMessage: Sendable {
    case text(String)
    case binary(Data)
}

/// A single WebSocket connection, handed to `app.mapWebSocket(_:_:)` handlers
/// (the realtime and OpenAPI contract design). Wraps the NIO WebSocket frame machinery so handler code is plain
/// `async`/`await` with no NIO types in the public surface.
public final class WebSocket: Sendable {
    /// What a transport provides to back a `WebSocket`: the NIO upgrade path (`init(channel:)`) and
    /// any other carrier (an opt-in module, a test double) supply the same three operations.
    public struct Transport: Sendable {
        /// Incoming messages; completes when the peer or the socket closes. Called once per `messages()`;
        /// a transport may support a single consumer only (the NIO one does), so handlers iterate it once.
        public let messages: @Sendable () -> AsyncThrowingStream<WebSocketMessage, Error>
        /// Delivers one message to the peer.
        public let send: @Sendable (WebSocketMessage) async throws -> Void
        /// Closes the connection with the given code (called at most once).
        public let close: @Sendable (WebSocketErrorCode) async -> Void

        public init(
            messages: @escaping @Sendable () -> AsyncThrowingStream<WebSocketMessage, Error>,
            send: @escaping @Sendable (WebSocketMessage) async throws -> Void,
            close: @escaping @Sendable (WebSocketErrorCode) async -> Void
        ) {
            self.messages = messages
            self.send = send
            self.close = close
        }
    }

    private let transport: Transport
    private let isClosed = NIOLockedValueBox(false)

    public init(transport: Transport) {
        self.transport = transport
    }

    convenience init(channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) {
        self.init(transport: Transport(
            messages: { Self.messages(of: channel) },
            send: { message in
                switch message {
                case .text(let text):
                    var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
                    buffer.writeString(text)
                    try await channel.outbound.write(WebSocketFrame(fin: true, opcode: .text, data: buffer))
                case .binary(let data):
                    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    try await channel.outbound.write(WebSocketFrame(fin: true, opcode: .binary, data: buffer))
                }
            },
            close: { code in
                var buffer = ByteBufferAllocator().buffer(capacity: 2)
                buffer.write(webSocketErrorCode: code)
                try? await channel.outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer))
                try? await channel.channel.close()
            }
        ))
    }

    /// An async sequence of incoming messages. Completes when the peer
    /// closes the connection or the socket is closed locally.
    public func messages() -> AsyncThrowingStream<WebSocketMessage, Error> {
        transport.messages()
    }

    /// Sends a text message to the peer.
    public func send(_ text: String) async throws {
        try await transport.send(.text(text))
    }

    /// Sends a binary message to the peer.
    public func send(_ data: Data) async throws {
        try await transport.send(.binary(data))
    }

    /// Closes the connection with the given close code.
    public func close(code: WebSocketErrorCode = .normalClosure) async throws {
        let alreadyClosed = isClosed.withLockedValue { closed -> Bool in
            let wasClosed = closed
            closed = true
            return wasClosed
        }
        guard !alreadyClosed else { return }
        await transport.close(code)
    }

    private static func messages(of channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) -> AsyncThrowingStream<WebSocketMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in channel.inbound {
                        switch frame.opcode {
                        case .text:
                            var buffer = frame.unmaskedData
                            let text = buffer.readString(length: buffer.readableBytes) ?? ""
                            continuation.yield(.text(text))
                        case .binary:
                            var buffer = frame.unmaskedData
                            let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
                            continuation.yield(.binary(Data(bytes)))
                        case .connectionClose:
                            continuation.finish()
                            return
                        case .ping, .pong, .continuation:
                            continue
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A handler for one WebSocket connection, as passed to `app.mapWebSocket`.
public typealias WebSocketHandler = @Sendable (WebSocket) async throws -> Void

/// A single registered WebSocket route (path + handler + auth), matched by
/// the server engine during the HTTP upgrade handshake.
struct WebSocketRoute: Sendable {
    let path: String
    let auth: AuthRequirement
    let handler: WebSocketHandler
}

/// The registry of WebSocket routes, separate from the HTTP `Router` since
/// WebSocket connections upgrade once and then leave the HTTP request/response
/// cycle entirely.
final class WebSocketRegistry: @unchecked Sendable {
    private var routes: [WebSocketRoute] = []
    private let lock = NSLock()

    func register(path: String, auth: AuthRequirement, handler: @escaping WebSocketHandler) {
        lock.lock()
        defer { lock.unlock() }
        routes.append(WebSocketRoute(path: path, auth: auth, handler: handler))
    }

    func match(path: String) -> WebSocketRoute? {
        lock.lock()
        defer { lock.unlock() }
        return routes.first { $0.path == path }
    }
}

extension WebApplication {
    /// Registers a WebSocket route at `path` (the realtime and OpenAPI contract design), upgraded from the same
    /// HTTP/HTTPS listener via `NIOWebSocket`. `handler` runs for the
    /// lifetime of the connection.
    @discardableResult
    public func mapWebSocket(_ path: String, auth: AuthRequirement = .none, _ handler: @escaping WebSocketHandler) -> Self {
        webSocketRegistry.register(path: path, auth: auth, handler: handler)
        return self
    }
}
