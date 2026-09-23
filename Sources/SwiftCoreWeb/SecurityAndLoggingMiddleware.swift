// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import os

private let routingLogger = Logger(subsystem: "SwiftCoreWeb", category: "routing")

extension WebApplication {
    /// Adds baseline security response headers (the middleware pipeline design): `X-Content-Type-Options`,
    /// `X-Frame-Options`, a basic `Content-Security-Policy`, and `Referrer-Policy`.
    @discardableResult
    public func useSecurityHeaders() -> Self {
        use { ctx, next in
            try await next()
            ctx.response.headers["X-Content-Type-Options"] = "nosniff"
            ctx.response.headers["X-Frame-Options"] = "DENY"
            ctx.response.headers["Content-Security-Policy"] = "default-src 'self'"
            ctx.response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        }
    }

    /// Logs method, path, status, and duration for every request via `os.Logger` (the middleware pipeline design).
    @discardableResult
    public func useRequestLogging() -> Self {
        use { ctx, next in
            let start = DispatchTime.now()
            defer {
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                routingLogger.info("\(ctx.request.method.rawValue, privacy: .public) \(ctx.request.path, privacy: .public) -> \(ctx.response.status.rawValue, privacy: .public) (\(String(format: "%.1f", elapsedMs), privacy: .public)ms)")
            }
            try await next()
        }
    }
}
