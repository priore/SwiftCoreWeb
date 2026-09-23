// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

extension WebApplication {
    /// Creates a route group under `prefix` (the Minimal API closure routing design:
    /// `app.mapGroup("/api").requireAuthorization()`), sharing this
    /// application's router.
    public func mapGroup(_ prefix: String) -> RouteGroup {
        RouteGroup(prefix: prefix, router: routeRegistry)
    }

    /// Registers a `GET` route with a closure handler.
    @discardableResult
    public func mapGet<T: Sendable>(
        _ path: String,
        auth: AuthRequirement = .none,
        summary: String? = nil,
        _ handler: @escaping @Sendable (HttpContext) async throws -> T
    ) -> Self {
        map(.get, path, auth: auth, summary: summary, handler)
    }

    /// Registers a `POST` route with a closure handler.
    @discardableResult
    public func mapPost<T: Sendable>(
        _ path: String,
        auth: AuthRequirement = .none,
        summary: String? = nil,
        _ handler: @escaping @Sendable (HttpContext) async throws -> T
    ) -> Self {
        map(.post, path, auth: auth, summary: summary, handler)
    }

    /// Registers a `PUT` route with a closure handler.
    @discardableResult
    public func mapPut<T: Sendable>(
        _ path: String,
        auth: AuthRequirement = .none,
        summary: String? = nil,
        _ handler: @escaping @Sendable (HttpContext) async throws -> T
    ) -> Self {
        map(.put, path, auth: auth, summary: summary, handler)
    }

    /// Registers a `PATCH` route with a closure handler.
    @discardableResult
    public func mapPatch<T: Sendable>(
        _ path: String,
        auth: AuthRequirement = .none,
        summary: String? = nil,
        _ handler: @escaping @Sendable (HttpContext) async throws -> T
    ) -> Self {
        map(.patch, path, auth: auth, summary: summary, handler)
    }

    /// Registers a `DELETE` route with a closure handler.
    @discardableResult
    public func mapDelete<T: Sendable>(
        _ path: String,
        auth: AuthRequirement = .none,
        summary: String? = nil,
        _ handler: @escaping @Sendable (HttpContext) async throws -> T
    ) -> Self {
        map(.delete, path, auth: auth, summary: summary, handler)
    }

    /// Registers a `HEAD` route with a closure handler. `GET` routes are
    /// automatically served for `HEAD` unless overridden by an explicit
    /// route like this one.
    @discardableResult
    public func mapHead<T: Sendable>(
        _ path: String,
        auth: AuthRequirement = .none,
        summary: String? = nil,
        _ handler: @escaping @Sendable (HttpContext) async throws -> T
    ) -> Self {
        map(.head, path, auth: auth, summary: summary, handler)
    }

    /// Registers an `OPTIONS` route with a closure handler. `OPTIONS` is
    /// otherwise answered automatically unless overridden by a route like this one.
    @discardableResult
    public func mapOptions<T: Sendable>(
        _ path: String,
        auth: AuthRequirement = .none,
        summary: String? = nil,
        _ handler: @escaping @Sendable (HttpContext) async throws -> T
    ) -> Self {
        map(.options, path, auth: auth, summary: summary, handler)
    }

    /// Registers the same handler for multiple HTTP methods on one path.
    @discardableResult
    public func mapMethods<T: Sendable>(
        _ methods: [HttpMethod],
        _ path: String,
        auth: AuthRequirement = .none,
        summary: String? = nil,
        _ handler: @escaping @Sendable (HttpContext) async throws -> T
    ) -> Self {
        for method in methods {
            _ = map(method, path, auth: auth, summary: summary, handler)
        }
        return self
    }

    /// `Void`-returning overloads (`204 No Content`) of the `map*` methods
    /// above, since `Void` cannot conform to `HttpResultConvertible`.
    /// `@_disfavoredOverload`: without it, a trailing closure whose single
    /// expression throws before producing its value (e.g. `{ ctx in
    /// SomeType(try bindRouteValue(...)) }`) type-checks against *both* this
    /// overload and the generic one, and overload resolution silently picks
    /// this `Void` one — discarding the handler's real result with only an
    /// "unused result" warning instead of registering the intended response.
    @_disfavoredOverload
    @discardableResult
    public func mapGet(_ path: String, auth: AuthRequirement = .none, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.get, path, auth: auth, summary: summary, handler)
    }

    @_disfavoredOverload
    @discardableResult
    public func mapPost(_ path: String, auth: AuthRequirement = .none, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.post, path, auth: auth, summary: summary, handler)
    }

    @_disfavoredOverload
    @discardableResult
    public func mapPut(_ path: String, auth: AuthRequirement = .none, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.put, path, auth: auth, summary: summary, handler)
    }

    @_disfavoredOverload
    @discardableResult
    public func mapPatch(_ path: String, auth: AuthRequirement = .none, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.patch, path, auth: auth, summary: summary, handler)
    }

    @_disfavoredOverload
    @discardableResult
    public func mapDelete(_ path: String, auth: AuthRequirement = .none, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.delete, path, auth: auth, summary: summary, handler)
    }

    @_disfavoredOverload
    @discardableResult
    public func mapHead(_ path: String, auth: AuthRequirement = .none, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.head, path, auth: auth, summary: summary, handler)
    }

    @_disfavoredOverload
    @discardableResult
    public func mapOptions(_ path: String, auth: AuthRequirement = .none, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.options, path, auth: auth, summary: summary, handler)
    }

    /// Registers all routes declared by the given `@Controller` types.
    /// Registration is explicit: only the types listed here are registered,
    /// with zero runtime type discovery.
    @discardableResult
    public func mapControllers(_ controllers: RouteProvider.Type...) -> Self {
        for controller in controllers {
            controller.registerRoutes(into: routeRegistry)
        }
        return self
    }

    private func map<T: Sendable>(
        _ method: HttpMethod,
        _ path: String,
        auth: AuthRequirement,
        summary: String?,
        _ handler: @escaping @Sendable (HttpContext) async throws -> T
    ) -> Self {
        routeRegistry.register(method: method, path: path, auth: auth, summary: summary) { ctx in
            try makeHttpResult(try await handler(ctx))
        }
        return self
    }

    /// `Void`-returning overload (`204 No Content`), since `Void` cannot
    /// conform to `HttpResultConvertible` (see `voidHttpResult()`).
    @_disfavoredOverload
    private func map(
        _ method: HttpMethod,
        _ path: String,
        auth: AuthRequirement,
        summary: String?,
        _ handler: @escaping @Sendable (HttpContext) async throws -> Void
    ) -> Self {
        routeRegistry.register(method: method, path: path, auth: auth, summary: summary) { ctx in
            try await handler(ctx)
            return voidHttpResult()
        }
        return self
    }
}
