// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

extension WebApplication {
    /// Serves a Vue `dist/` build from `root` with history-mode SPA fallback
    /// (the SPA hosting design), in one line:
    ///
    /// ```swift
    /// app.useSpa(root: .bundle("dist"))
    /// ```
    ///
    /// Serves static files under `root` first (identical rules to
    /// `.useStaticFiles`); a `GET` that matches no file and no API route,
    /// and whose `Accept` header allows `text/html`, falls back to
    /// `index.html` so Vue Router deep links resolve client-side. API
    /// routes always win — this middleware only ever answers a request the
    /// rest of the pipeline (registered routes) did not already handle, and
    /// an unmatched `/api/*` path still falls through to the router's own
    /// JSON `404`, never to `index.html`.
    @discardableResult
    public func useSpa(root: ContentRoot, apiPrefix: String = "/api") -> Self {
        return use { ctx, next in
            guard ctx.request.method == .get || ctx.request.method == .head else {
                try await next(); return
            }
            guard let rootPath = resolveContentRoot(root) else {
                try await next(); return
            }

            if let filePath = resolveStaticFilePath(root: rootPath, requestPath: ctx.request.path) {
                ctx.response = try staticFileResponse(filePath: filePath, requestPath: ctx.request.path, request: ctx.request)
                return
            }

            // Let a registered API route answer (and produce its own 404)
            // before falling back to index.html.
            try await next()
            guard ctx.response.status == .notFound else { return }
            guard !ctx.request.path.hasPrefix(apiPrefix) else { return }

            let accept = ctx.request.headers["Accept"] ?? ""
            guard accept.isEmpty || accept.contains("text/html") || accept.contains("*/*") else { return }

            guard let indexPath = resolveStaticFilePath(root: rootPath, requestPath: "/index.html") else { return }
            ctx.response = try staticFileResponse(filePath: indexPath, requestPath: "/index.html", request: ctx.request)
        }
    }
}
