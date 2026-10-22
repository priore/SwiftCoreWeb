// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// Metadata describing a single registered route, used for `Allow` headers,
/// the dev-only `/__routes` list, and `/openapi.json` generation.
public struct RouteMetadata: Sendable {
    public let method: HttpMethod
    public let path: String
    public let auth: AuthRequirement
    public let summary: String?

    public init(method: HttpMethod, path: String, auth: AuthRequirement, summary: String?) {
        self.method = method
        self.path = path
        self.auth = auth
        self.summary = summary
    }
}

/// A route handler bound to a concrete `HttpContext`, returning a value
/// convertible to `HttpResult`. Every closure `map*` overload and every
/// `@Controller`-generated registration produces one of these.
public typealias RouteHandler = @Sendable (HttpContext) async throws -> any HttpResultConvertible

/// The registration surface a `RouteProvider` writes its routes into.
///
/// Implemented by the router (the early-gate rate limiting design, delivered in Part 3). `@Controller`'s
/// generated `registerRoutes(into:)` and the closure `map*` overloads both
/// call `register(_:)` — one code path, no reflection-based discovery.
public protocol RouteRegistry: AnyObject, Sendable {
    func register(
        method: HttpMethod,
        path: String,
        auth: AuthRequirement,
        summary: String?,
        handler: @escaping RouteHandler
    )

    /// `register` with a per-route request body limit (`nil` = the global limit).
    func register(
        method: HttpMethod,
        path: String,
        auth: AuthRequirement,
        summary: String?,
        maxBodySize: Int?,
        handler: @escaping RouteHandler
    )
}

extension RouteRegistry {
    /// Default for registries that do not support per-route limits: the limit is ignored.
    public func register(
        method: HttpMethod,
        path: String,
        auth: AuthRequirement,
        summary: String?,
        maxBodySize: Int?,
        handler: @escaping RouteHandler
    ) {
        register(method: method, path: path, auth: auth, summary: summary, handler: handler)
    }
}

/// A type that can register its routes with a `RouteRegistry`.
///
/// `@Controller` generates this conformance at compile time. Registration
/// stays explicit: `app.mapControllers(UserController.self, OrderController.self)`
/// calls `registerRoutes(into:)` on each listed type — no type discovery.
public protocol RouteProvider {
    static func registerRoutes(into router: RouteRegistry)
}
