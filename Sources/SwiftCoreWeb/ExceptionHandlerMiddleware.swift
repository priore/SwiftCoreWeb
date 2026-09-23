// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import os

private let logger = Logger(subsystem: "SwiftCoreWeb", category: "server")

extension WebApplication {
    /// Traps thrown errors from the rest of the pipeline and the route
    /// handler, converting them to RFC 9457 ProblemDetails JSON (the middleware pipeline design).
    ///
    /// Always register this first so it wraps every later middleware step.
    /// `HttpError`/`ProblemDetails` map to their carried status; any other
    /// error becomes `500`. The error's detail (or description, in
    /// `.development`) is only included in the response body outside
    /// `.production` — production responses never leak internal error text.
    @discardableResult
    public func useExceptionHandler() -> Self {
        let isDevelopment = environment == .development
        return use { ctx, next in
            do {
                try await next()
            } catch let httpError as HttpError {
                logger.error("Unhandled HttpError: \(httpError.status.rawValue, privacy: .public) \(httpError.detail ?? "", privacy: .private)")
                let detail = isDevelopment ? httpError.detail : nil
                ctx.response = try Results.problem(status: httpError.status, detail: detail).response
            } catch let problem as ProblemDetails {
                logger.error("Unhandled ProblemDetails: \(problem.status, privacy: .public)")
                var adjusted = problem
                if !isDevelopment { adjusted.detail = nil }
                ctx.response = try Results.json(adjusted, status: HttpStatusCode(problem.status)).response
            } catch {
                logger.error("Unhandled error: \(String(describing: error), privacy: .private)")
                let detail = isDevelopment ? String(describing: error) : nil
                ctx.response = try Results.problem(status: .internalServerError, detail: detail).response
            }
        }
    }
}
