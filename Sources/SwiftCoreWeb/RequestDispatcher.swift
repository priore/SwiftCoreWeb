// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// Ties routing (`Router.match`), the middleware pipeline, and route
/// dispatch together into the single entry point the server engine (Part 4)
/// calls per request. Kept separate from the NIO-facing engine so it can
/// also back `SwiftCoreWebTesting.TestHost` (the testing support design) without any socket code.
public struct RequestDispatcher: Sendable {
    let router: Router
    let pipeline: MiddlewarePipeline
    let services: ServiceProvider
    let metrics: ServerMetrics

    init(router: Router, pipeline: MiddlewarePipeline, services: ServiceProvider, metrics: ServerMetrics) {
        self.router = router
        self.pipeline = pipeline
        self.services = services
        self.metrics = metrics
    }

    /// Dispatches one request end to end: matches the route (applying the
    /// HEAD/OPTIONS/404/405 rules of the HTTP methods/HEAD/OPTIONS routing rules), runs the middleware pipeline,
    /// and returns the resulting `HttpResponse`. `HEAD` responses keep every
    /// header (including `Content-Length`) but the caller must drop the
    /// body bytes, per the HTTP methods/HEAD/OPTIONS routing rules.
    ///
    /// Records the completed request in `metrics` regardless of caller
    /// (`ServerEngine` or `SwiftCoreWebTesting.TestHost`), since both route
    /// through here — the single point that sees every request either way.
    public func dispatch(_ request: HttpRequest) async -> HttpResponse {
        let startedAt = DispatchTime.now()
        let response = await dispatchWithoutMetrics(request)
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        metrics.recordRequest(
            method: request.method.rawValue,
            path: request.path,
            statusCode: response.status.rawValue,
            durationMilliseconds: elapsedMilliseconds,
            byteCount: response.body.byteCount,
            clientIP: request.remoteAddress ?? "unknown"
        )
        return response
    }

    private func dispatchWithoutMetrics(_ request: HttpRequest) async -> HttpResponse {
        let ctx = HttpContext(request: request, services: services)

        let match = router.match(method: request.method, path: request.path)
        let routeAuth: AuthRequirement
        let terminal: MiddlewareNext

        switch match {
        case .matched(let route, let routeValues):
            routeAuth = route.auth
            let boundRequest = HttpRequest(
                method: request.method,
                path: request.path,
                routeValues: routeValues,
                query: request.query,
                queryAll: request.queryAll,
                headers: request.headers,
                remoteAddress: request.remoteAddress,
                body: request.body
            )
            let boundCtx = HttpContext(request: boundRequest, services: services, user: ctx.user, items: ctx.items)
            return await runPipeline(boundCtx, routeAuth: routeAuth) {
                let result = try await route.handler(boundCtx)
                boundCtx.response = try result.toHttpResult().response
            }

        case .methodNotAllowed(let allowedMethods):
            routeAuth = .none
            if request.method == .options {
                terminal = {
                    ctx.response = HttpResponse(status: .noContent, headers: allowHeader(allowedMethods))
                }
            } else {
                terminal = {
                    ctx.response = HttpResponse(status: .methodNotAllowed, headers: allowHeader(allowedMethods))
                }
            }
            return await runPipeline(ctx, routeAuth: routeAuth, terminal)

        case .notFound:
            routeAuth = .none
            terminal = {
                ctx.response = Results.notFound().response
            }
            return await runPipeline(ctx, routeAuth: routeAuth, terminal)
        }
    }

    private func runPipeline(_ ctx: HttpContext, routeAuth: AuthRequirement, _ terminal: @escaping MiddlewareNext) async -> HttpResponse {
        ctx.items[MatchedRouteAuth.self] = MatchedRouteAuth(requirement: routeAuth)
        do {
            try await pipeline.run(ctx, terminal: terminal)
        } catch {
            // A thrown error that escapes the whole pipeline means
            // `.useExceptionHandler()` was not registered (or itself threw).
            // Fail safe with a bare 500 rather than crash the connection.
            ctx.response = HttpResponse(status: .internalServerError)
        }
        return ctx.response
    }
}

private func allowHeader(_ methods: Set<HttpMethod>) -> HttpHeaders {
    var headers = HttpHeaders()
    headers["Allow"] = methods.map(\.rawValue).sorted().joined(separator: ", ")
    return headers
}

extension WebApplication {
    /// Freezes the router and middleware pipeline and builds the
    /// `RequestDispatcher` the server engine (Part 4) and `TestHost` (the testing support design)
    /// drive requests through. Idempotent: safe to call once from
    /// `runAsync()` and again from `TestHost`.
    public func buildDispatcher() -> RequestDispatcher {
        routeRegistry.freeze()
        return RequestDispatcher(router: routeRegistry, pipeline: middlewarePipeline, services: services, metrics: metrics)
    }
}
