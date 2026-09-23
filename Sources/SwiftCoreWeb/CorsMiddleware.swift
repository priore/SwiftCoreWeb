// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// Matches an allowed-origin pattern against a request's `Origin` header.
/// Supports an exact match or a single leading wildcard host label
/// (`http://*.local:5173`, per the middleware pipeline design's documented development preset).
private func originMatches(_ pattern: String, _ origin: String) -> Bool {
    guard let wildcardRange = pattern.range(of: "*") else {
        return pattern == origin
    }
    let prefix = pattern[pattern.startIndex..<wildcardRange.lowerBound]
    let suffix = pattern[wildcardRange.upperBound...]
    return origin.hasPrefix(prefix) && origin.hasSuffix(suffix) && origin.count >= prefix.count + suffix.count
}

extension WebApplication {
    /// Configures CORS (the middleware pipeline design): allowed origins, methods, headers, credentials,
    /// and preflight `OPTIONS` handling with `Access-Control-Max-Age`.
    ///
    /// ```swift
    /// app.useCors { $0.allowedOrigins = ["https://example.com"] }
    /// ```
    @discardableResult
    public func useCors(_ configure: (inout CorsOptions) -> Void = { _ in }) -> Self {
        var mutableOptions = corsOptions
        configure(&mutableOptions)
        let options = mutableOptions
        return use { ctx, next in
            guard let origin = ctx.request.headers["Origin"] else {
                try await next()
                return
            }
            guard options.allowedOrigins.contains(where: { originMatches($0, origin) }) else {
                try await next()
                return
            }

            ctx.response.headers["Access-Control-Allow-Origin"] = origin
            ctx.response.headers["Vary"] = "Origin"
            if options.allowCredentials {
                ctx.response.headers["Access-Control-Allow-Credentials"] = "true"
            }

            if ctx.request.method == .options, ctx.request.headers["Access-Control-Request-Method"] != nil {
                // Preflight: answer directly, never reaching the route handler.
                ctx.response.status = .noContent
                ctx.response.headers["Access-Control-Allow-Methods"] = options.allowedMethods.joined(separator: ", ")
                ctx.response.headers["Access-Control-Allow-Headers"] = options.allowedHeaders.joined(separator: ", ")
                ctx.response.headers["Access-Control-Max-Age"] = String(options.maxAgeSeconds)
                return
            }

            try await next()
        }
    }
}
