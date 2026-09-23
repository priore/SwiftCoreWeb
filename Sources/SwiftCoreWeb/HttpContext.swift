// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// Per-request typed storage for middleware to pass data down the pipeline.
///
/// Keyed by type via `ObjectIdentifier`, mirroring `ServiceProvider` — no
/// stringly-typed keys, no reflection.
public final class RequestItems: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    public subscript<T: Sendable>(type: T.Type) -> T? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage[ObjectIdentifier(type)] as? T
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage[ObjectIdentifier(type)] = newValue
        }
    }
}

/// The per-request context passed to every middleware and handler.
///
/// Wraps the strongly-typed `HttpRequest`/`HttpResponse` pair; NIO types
/// never appear here. Middleware mutate `response` before calling `next()`
/// completes, or short-circuit by not calling `next()` at all.
public final class HttpContext: @unchecked Sendable {
    /// The incoming request.
    public let request: HttpRequest

    /// The outgoing response, mutated by the handler and middleware chain.
    public var response: HttpResponse

    /// The authenticated identity for this request, or `nil` if anonymous.
    /// Populated by `.useAuthentication()`.
    public var user: ClaimsPrincipal?

    /// The resolved service container for this application.
    public let services: ServiceProvider

    /// Per-request typed storage for middleware.
    public let items: RequestItems

    public init(
        request: HttpRequest,
        services: ServiceProvider,
        response: HttpResponse = HttpResponse(),
        user: ClaimsPrincipal? = nil,
        items: RequestItems = RequestItems()
    ) {
        self.request = request
        self.services = services
        self.response = response
        self.user = user
        self.items = items
    }
}
