// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// The `next` continuation passed to a middleware closure. Calling it
/// invokes the remainder of the pipeline (and, at the end, the matched
/// route handler); not calling it short-circuits the request.
public typealias MiddlewareNext = @Sendable () async throws -> Void

/// A single middleware step: `IApplicationBuilder`-style (the middleware pipeline design).
public typealias MiddlewareHandler = @Sendable (HttpContext, MiddlewareNext) async throws -> Void

/// A reusable middleware component, for cases where a closure is unwieldy.
public protocol Middleware: Sendable {
    func handle(_ ctx: HttpContext, _ next: MiddlewareNext) async throws
}

/// The sequential async middleware pipeline. Order equals registration
/// order; the terminal step (added by the server engine) dispatches to the
/// matched route handler.
struct MiddlewarePipeline: Sendable {
    private(set) var steps: [MiddlewareHandler] = []

    mutating func append(_ handler: @escaping MiddlewareHandler) {
        steps.append(handler)
    }

    /// Runs the pipeline against `ctx`, ending with `terminal` (route
    /// dispatch) if every step calls `next()`.
    func run(_ ctx: HttpContext, terminal: @escaping MiddlewareNext) async throws {
        try await runStep(0, ctx, terminal: terminal)
    }

    private func runStep(_ index: Int, _ ctx: HttpContext, terminal: @escaping MiddlewareNext) async throws {
        guard index < steps.count else {
            try await terminal()
            return
        }
        let step = steps[index]
        try await step(ctx) {
            try await runStep(index + 1, ctx, terminal: terminal)
        }
    }
}

extension WebApplication {
    /// Appends a middleware step to the pipeline (the middleware pipeline design).
    /// ```swift
    /// app.use { ctx, next in
    ///     // before
    ///     try await next()
    ///     // after
    /// }
    /// ```
    @discardableResult
    public func use(_ handler: @escaping MiddlewareHandler) -> Self {
        middlewarePipeline.append(handler)
        return self
    }

    /// Appends a reusable `Middleware` component to the pipeline.
    @discardableResult
    public func use(_ middleware: some Middleware) -> Self {
        middlewarePipeline.append { ctx, next in
            try await middleware.handle(ctx, next)
        }
        return self
    }
}
