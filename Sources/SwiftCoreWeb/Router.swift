// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// A single compiled route entry, produced from either a closure `map*`
/// registration or `@Controller`-generated code — one code path, per the pluggable authentication schemes design.
struct Route: Sendable {
    let method: HttpMethod
    let template: CompiledRouteTemplate
    let auth: AuthRequirement
    let summary: String?
    let handler: RouteHandler
}

/// The outcome of matching a request path against the router.
enum RouteMatch: Sendable {
    /// A route matched both path and method.
    case matched(Route, routeValues: [String: String])
    /// The path matched at least one route, but not for this method.
    /// Carries the set of methods that *do* match, for the `Allow` header.
    case methodNotAllowed(allowedMethods: Set<HttpMethod>)
    /// No route matched the path at all.
    case notFound
}

/// The immutable, `Sendable` router built from all `map*`/`mapControllers`
/// registrations at `WebApplication.build()`/first `runAsync()` time.
///
/// Lock-free on reads per the concurrency/lifecycle/network watchdog design: routes never change after construction, so
/// concurrent requests match against the same frozen array with no locking.
final class Router: RouteRegistry, @unchecked Sendable {
    private var pendingRoutes: [Route] = []
    private var frozenRoutes: [Route] = []
    private var isFrozen = false
    private let lock = NSLock()

    /// Registers a route. Called by the closure `map*` overloads and by
    /// `@Controller`-generated `registerRoutes(into:)`. Valid only before
    /// `freeze()` — the router is immutable once the server starts.
    func register(
        method: HttpMethod,
        path: String,
        auth: AuthRequirement,
        summary: String?,
        handler: @escaping RouteHandler
    ) {
        lock.lock()
        defer { lock.unlock() }
        precondition(!isFrozen, "SwiftCoreWeb: cannot register routes after the router has been frozen (runAsync() was called)")
        guard let template = try? CompiledRouteTemplate(path) else {
            preconditionFailure("SwiftCoreWeb: invalid route template '\(path)'")
        }
        pendingRoutes.append(Route(method: method, template: template, auth: auth, summary: summary, handler: handler))
    }

    /// Freezes the router, taking a stable snapshot for lock-free matching.
    /// Called once by the server engine before accepting connections.
    func freeze() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFrozen else { return }
        let ambiguous = Self.ambiguousRouteGroups(pendingRoutes)
        if !ambiguous.isEmpty {
            // Printed before the trap so the full list shows in the Xcode console, one route per line.
            let report = ambiguous.map { group in
                group.map { "  \($0.method.rawValue) \($0.template.raw)" }.joined(separator: "\n")
            }.joined(separator: "\n  --\n")
            fputs("""
            SwiftCoreWeb: ambiguous routes. These routes share the same method and shape, so only the first of each group is reachable:
            \(report)
            Fix: rename or remove one of each group, or give the placeholders different constraints (e.g. {id:int} and {id:uuid}).

            """, stderr)
            preconditionFailure("SwiftCoreWeb: \(ambiguous.count) group(s) of ambiguous routes, see the list printed above")
        }
        isFrozen = true
        frozenRoutes = pendingRoutes
    }

    /// Groups of routes that share method and template shape (`/users/{id}`
    /// vs `/users/{name}`); only the first of each could ever be reached.
    /// Different constraints give different shapes (`{id:int}` vs `{id:uuid}`),
    /// so overlapping-but-unequal constraints are not reported — precedence
    /// decides those.
    static func ambiguousRouteGroups(_ routes: [Route]) -> [[Route]] {
        var order: [String] = []
        var groups: [String: [Route]] = [:]
        for route in routes {
            let key = "\(route.method.rawValue) \(route.template.shapeKey)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(route)
        }
        return order.compactMap { groups[$0] }.filter { $0.count > 1 }
    }

    /// All registered routes, for `/__routes` and `/openapi.json` (the realtime and OpenAPI contract design).
    var allRoutes: [Route] {
        lock.lock()
        defer { lock.unlock() }
        return isFrozen ? frozenRoutes : pendingRoutes
    }

    /// Matches `method`/`path` against the frozen route table.
    ///
    /// Implements the HTTP methods/HEAD/OPTIONS routing rules: `HEAD` falls back to a matching `GET` route (same
    /// headers, no body — the server engine drops the body when writing the
    /// response) unless an explicit `HEAD` route exists; `OPTIONS` is
    /// synthesized from the path's allowed methods unless an explicit
    /// `OPTIONS` route exists; a path match with no method match is `405`
    /// with `Allow`; no path match at all is `404`.
    func match(method: HttpMethod, path: String) -> RouteMatch {
        let components = splitPathComponents(path)
        var candidatesByMethod: [HttpMethod: (Route, [String: String])] = [:]

        for route in allRoutes {
            guard let values = route.template.match(pathComponents: components) else { continue }
            // For a given method the strictly more specific route wins,
            // whatever the registration order (see `precedence`).
            if let existing = candidatesByMethod[route.method],
               !route.template.precedence.lexicographicallyPrecedes(existing.0.template.precedence) { continue }
            candidatesByMethod[route.method] = (route, values)
        }

        if let exact = candidatesByMethod[method] {
            return .matched(exact.0, routeValues: exact.1)
        }

        if method == .head, let getRoute = candidatesByMethod[.get] {
            return .matched(getRoute.0, routeValues: getRoute.1)
        }

        if !candidatesByMethod.isEmpty {
            var allowed = Set(candidatesByMethod.keys)
            if candidatesByMethod[.get] != nil { allowed.insert(.head) }
            allowed.insert(.options)
            if method == .options {
                // Synthesized OPTIONS response; the pipeline builds the
                // actual 204 + Allow header from `methodNotAllowed`'s set
                // when no explicit OPTIONS handler exists.
                return .methodNotAllowed(allowedMethods: allowed)
            }
            return .methodNotAllowed(allowedMethods: allowed)
        }

        return .notFound
    }
}

/// A group of routes sharing a path prefix and, optionally, a default
/// authorization requirement (the Minimal API closure routing design: `app.mapGroup("/api").requireAuthorization()`).
///
/// Mirrors the `WebApplication` closure `map*` surface so junior code reads
/// identically whether routes are grouped or not.
public final class RouteGroup: @unchecked Sendable {
    let prefix: String
    let router: Router
    private var defaultAuth: AuthRequirement

    init(prefix: String, router: Router, defaultAuth: AuthRequirement = .none) {
        self.prefix = prefix
        self.router = router
        self.defaultAuth = defaultAuth
    }

    /// Requires authentication (or a specific requirement) for every route
    /// registered on this group afterward, unless a route overrides `auth:` explicitly.
    @discardableResult
    public func requireAuthorization(_ requirement: AuthRequirement = .authenticated) -> Self {
        defaultAuth = requirement
        return self
    }

    /// Creates a nested group, concatenating path prefixes and inheriting
    /// this group's default authorization requirement.
    public func mapGroup(_ prefix: String) -> RouteGroup {
        RouteGroup(prefix: self.prefix + prefix, router: router, defaultAuth: defaultAuth)
    }

    func fullPath(_ path: String) -> String {
        let combined = prefix + (path.hasPrefix("/") || prefix.isEmpty ? path : "/" + path)
        return combined.isEmpty ? "/" : combined
    }

    func effectiveAuth(_ auth: AuthRequirement?) -> AuthRequirement {
        auth ?? defaultAuth
    }
}

extension RouteGroup {
    @discardableResult
    public func mapGet<T: Sendable>(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> T) -> Self {
        map(.get, path, auth: auth, summary: summary, handler); return self
    }
    @discardableResult
    public func mapPost<T: Sendable>(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> T) -> Self {
        map(.post, path, auth: auth, summary: summary, handler); return self
    }
    @discardableResult
    public func mapPut<T: Sendable>(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> T) -> Self {
        map(.put, path, auth: auth, summary: summary, handler); return self
    }
    @discardableResult
    public func mapPatch<T: Sendable>(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> T) -> Self {
        map(.patch, path, auth: auth, summary: summary, handler); return self
    }
    @discardableResult
    public func mapDelete<T: Sendable>(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> T) -> Self {
        map(.delete, path, auth: auth, summary: summary, handler); return self
    }
    @discardableResult
    public func mapHead<T: Sendable>(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> T) -> Self {
        map(.head, path, auth: auth, summary: summary, handler); return self
    }
    @discardableResult
    public func mapOptions<T: Sendable>(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> T) -> Self {
        map(.options, path, auth: auth, summary: summary, handler); return self
    }
    @discardableResult
    public func mapMethods<T: Sendable>(_ methods: [HttpMethod], _ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> T) -> Self {
        for method in methods { map(method, path, auth: auth, summary: summary, handler) }
        return self
    }

    /// `Void`-returning overloads (`204 No Content`).
    @discardableResult
    public func mapGet(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.get, path, auth: auth, summary: summary, handler); return self
    }
    @discardableResult
    public func mapPost(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.post, path, auth: auth, summary: summary, handler); return self
    }
    @discardableResult
    public func mapPut(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.put, path, auth: auth, summary: summary, handler); return self
    }
    @discardableResult
    public func mapPatch(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.patch, path, auth: auth, summary: summary, handler); return self
    }
    @discardableResult
    public func mapDelete(_ path: String, auth: AuthRequirement? = nil, summary: String? = nil, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) -> Self {
        map(.delete, path, auth: auth, summary: summary, handler); return self
    }

    private func map<T: Sendable>(_ method: HttpMethod, _ path: String, auth: AuthRequirement?, summary: String?, _ handler: @escaping @Sendable (HttpContext) async throws -> T) {
        router.register(method: method, path: fullPath(path), auth: effectiveAuth(auth), summary: summary) { ctx in
            try makeHttpResult(try await handler(ctx))
        }
    }

    private func map(_ method: HttpMethod, _ path: String, auth: AuthRequirement?, summary: String?, _ handler: @escaping @Sendable (HttpContext) async throws -> Void) {
        router.register(method: method, path: fullPath(path), auth: effectiveAuth(auth), summary: summary) { ctx in
            try await handler(ctx)
            return voidHttpResult()
        }
    }
}
