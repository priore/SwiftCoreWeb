// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// The entry point for a transport that is not the HTTP listener (an opt-in module such as peer-to-peer):
/// the same dispatcher, connection gate and rate limiter the HTTP engine uses, so a request that arrives
/// another way meets the same routes, middleware and limits.
public struct RequestIngress: Sendable {
    let dispatcher: RequestDispatcher
    let rateLimiter: RateLimiter?
    let connectionGate: ConnectionGate
    let webSocketRegistry: WebSocketRegistry
    let metrics: ServerMetrics

    /// Reserves a connection slot (`maxConcurrentConnections`). `false` when at capacity: refuse the connection.
    /// Every `true` must be paired with `closeConnection()`.
    public func openConnection() async -> Bool {
        guard await connectionGate.tryAcquire() else {
            metrics.recordRejected(.atCapacity)
            return false
        }
        metrics.connectionOpened()
        return true
    }

    public func closeConnection() async {
        metrics.connectionClosed()
        await connectionGate.release()
    }

    /// Consumes one rate-limit token for `clientKey`. `false` when over the limit (answer 429); always `true`
    /// when no rate limit is configured. The key is whatever identifies the client for this transport.
    public func allowRequest(from clientKey: String) async -> Bool {
        guard let rateLimiter else { return true }
        guard await rateLimiter.allow(clientIP: clientKey) else {
            metrics.recordRejected(.rateLimited)
            return false
        }
        return true
    }

    /// The largest body accepted for `method`/`path`: the matched route's own limit, else the global one.
    /// Check it against the declared length before buffering the body.
    public func bodyLimit(method: HttpMethod, path: String) -> Int {
        dispatcher.bodyLimit(method: method, path: path)
    }

    /// Runs the request through routing and the middleware pipeline.
    public func dispatch(_ request: HttpRequest) async -> HttpResponse {
        await dispatcher.dispatch(request)
    }

    /// Serves a WebSocket route over `transport`. Returns `nil` once the handler has finished (the socket was
    /// accepted), or the response to send instead when there is no such route or its `auth` is not satisfied.
    public func acceptWebSocket(_ request: HttpRequest, transport: WebSocket.Transport) async -> HttpResponse? {
        guard let route = webSocketRegistry.match(path: request.path) else { return Results.notFound().response }
        if case .none = route.auth {} else if let denied = await dispatcher.authorizeUpgrade(request, auth: route.auth) {
            return denied
        }
        metrics.webSocketOpened()
        defer { metrics.webSocketClosed() }
        try? await route.handler(WebSocket(transport: transport))
        return nil
    }
}

/// A transport that runs next to the HTTP listener for as long as the server does (registered with
/// `WebApplicationBuilder.addExtension(_:)`). `start` runs once the listeners are bound; `stop` when the server stops.
public protocol ServerExtension: Sendable {
    func start(ingress: RequestIngress) async throws
    /// May run without a prior `start` (a failed bind) or more than once: keep it idempotent.
    func stop() async
}

extension WebApplicationBuilder {
    /// Runs `serverExtension` alongside the server. Not registered, not running: modules stay opt-in.
    @discardableResult
    public func addExtension(_ serverExtension: some ServerExtension) -> Self {
        extensions.append(serverExtension)
        return self
    }
}
