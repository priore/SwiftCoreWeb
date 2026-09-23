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
public final class WebSocket: @unchecked Sendable {
    private let channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
    private let isClosed = NIOLockedValueBox(false)

    init(channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) {
        self.channel = channel
    }

    /// An async sequence of incoming messages. Completes when the peer
    /// closes the connection or the socket is closed locally.
    public func messages() -> AsyncThrowingStream<WebSocketMessage, Error> {
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

    /// Sends a text message to the peer.
    public func send(_ text: String) async throws {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        try await send(WebSocketFrame(fin: true, opcode: .text, data: buffer))
    }

    /// Sends a binary message to the peer.
    public func send(_ data: Data) async throws {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await send(WebSocketFrame(fin: true, opcode: .binary, data: buffer))
    }

    /// Closes the connection with the given close code.
    public func close(code: WebSocketErrorCode = .normalClosure) async throws {
        let alreadyClosed = isClosed.withLockedValue { closed -> Bool in
            let wasClosed = closed
            closed = true
            return wasClosed
        }
        guard !alreadyClosed else { return }

        var buffer = ByteBufferAllocator().buffer(capacity: 2)
        buffer.write(webSocketErrorCode: code)
        try? await send(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer))
        try? await channel.channel.close()
    }

    private func send(_ frame: WebSocketFrame) async throws {
        try await channel.outbound.write(frame)
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
