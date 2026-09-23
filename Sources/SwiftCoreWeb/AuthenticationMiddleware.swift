// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import os

private let securityLogger = Logger(subsystem: "SwiftCoreWeb", category: "security")

/// Per-request storage key for the matched route's auth requirement, set by
/// the server engine's dispatch step before the pipeline runs so
/// `.useAuthorization()` can read it without re-matching the route.
struct MatchedRouteAuth: Sendable {
    let requirement: AuthRequirement
}

extension WebApplication {
    /// Registers one or more pluggable authentication schemes (the pluggable authentication schemes design).
    ///
    /// Every scheme runs, in registration order, until one resolves a
    /// principal; a scheme that throws (credential present but invalid)
    /// stops authentication immediately and rejects the request. A route
    /// with `auth: .none` (the default) never runs this middleware's work
    /// for that path — see `useAuthorization()`, which is where the actual
    /// per-route skip happens, since authentication itself is cheap and
    /// path-agnostic (it only reads headers already parsed for the request).
    @discardableResult
    public func useAuthentication(_ schemes: AnyAuthenticationScheme...) -> Self {
        useAuthentication(schemes)
    }

    @discardableResult
    public func useAuthentication(_ schemes: [AnyAuthenticationScheme]) -> Self {
        use { ctx, next in
            for scheme in schemes {
                if let principal = try await scheme.authenticate(ctx.request) {
                    ctx.user = principal
                    break
                }
            }
            try await next()
        }
    }

    /// Enforces the matched route's `AuthRequirement` (the pluggable authentication schemes design), populated on
    /// `ctx.items` by the server engine's dispatch step:
    /// - `.none`: always passes (and, per the pluggable authentication schemes design, this middleware's other
    ///   cases never run for such routes — no overhead).
    /// - `.authenticated`: any resolved `ctx.user` passes.
    /// - `.roles`: `ctx.user` must have at least one listed role.
    /// - `.scheme`: `ctx.user` must have been authenticated by that scheme.
    /// - `.policy`: resolved via `policies`, registered by name.
    ///
    /// Missing identity → `401` with `WWW-Authenticate`; identity present
    /// but insufficient → `403`. Both skip the route handler.
    @discardableResult
    public func useAuthorization(policies: [String: @Sendable (ClaimsPrincipal) -> Bool] = [:]) -> Self {
        use { ctx, next in
            let requirement = ctx.items[MatchedRouteAuth.self]?.requirement ?? .none
            switch requirement {
            case .none:
                break
            case .authenticated:
                guard ctx.user != nil else {
                    ctx.response = self.unauthorizedResponse()
                    return
                }
            case .roles(let roles):
                guard let user = ctx.user else {
                    ctx.response = self.unauthorizedResponse()
                    return
                }
                guard roles.contains(where: user.isInRole) else {
                    securityLogger.notice("Authorization denied: user lacks required role for \(ctx.request.path, privacy: .public)")
                    ctx.response = try Results.forbidden().response
                    return
                }
            case .scheme(let schemeName):
                guard let user = ctx.user, user.scheme == schemeName else {
                    ctx.response = ctx.user == nil ? self.unauthorizedResponse() : (try Results.forbidden().response)
                    return
                }
            case .policy(let policyName):
                guard let user = ctx.user else {
                    ctx.response = self.unauthorizedResponse()
                    return
                }
                guard let policy = policies[policyName], policy(user) else {
                    securityLogger.notice("Authorization denied: policy '\(policyName, privacy: .public)' failed for \(ctx.request.path, privacy: .public)")
                    ctx.response = try Results.forbidden().response
                    return
                }
            }
            try await next()
        }
    }

    private func unauthorizedResponse() -> HttpResponse {
        var response = (try? Results.unauthorized().response) ?? HttpResponse(status: .unauthorized)
        response.headers["WWW-Authenticate"] = "Bearer"
        return response
    }
}
