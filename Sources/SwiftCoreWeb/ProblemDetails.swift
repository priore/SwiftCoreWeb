// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// An RFC 9457 "Problem Details for HTTP APIs" payload.
///
/// Returned automatically by `.useExceptionHandler()` for thrown errors, and
/// by parameter-binding and routing failures. `detail` is only populated in
/// `.development` unless the error explicitly opts in.
public struct ProblemDetails: Codable, Sendable, Error {
    /// A URI reference identifying the problem type. Defaults to `"about:blank"`.
    public var type: String

    /// A short, human-readable summary of the problem type.
    public var title: String

    /// The HTTP status code generated for this occurrence of the problem.
    public var status: Int

    /// A human-readable explanation specific to this occurrence of the problem.
    public var detail: String?

    /// A URI reference identifying the specific occurrence of the problem.
    public var instance: String?

    public init(
        type: String = "about:blank",
        title: String,
        status: Int,
        detail: String? = nil,
        instance: String? = nil
    ) {
        self.type = type
        self.title = title
        self.status = status
        self.detail = detail
        self.instance = instance
    }
}

/// An error that carries an HTTP status code and an optional detail message.
///
/// Handlers may `throw HttpError(.notFound, "User not found")`. Caught by
/// `.useExceptionHandler()` and converted to a `ProblemDetails` JSON response
/// with the given status code.
public struct HttpError: Error, Sendable {
    public var status: HttpStatusCode
    public var detail: String?

    public init(_ status: HttpStatusCode, _ detail: String? = nil) {
        self.status = status
        self.detail = detail
    }
}

/// A standard HTTP response status code.
public struct HttpStatusCode: Sendable, Hashable, RawRepresentable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let ok = HttpStatusCode(200)
    public static let created = HttpStatusCode(201)
    public static let noContent = HttpStatusCode(204)
    public static let partialContent = HttpStatusCode(206)
    public static let notModified = HttpStatusCode(304)
    public static let badRequest = HttpStatusCode(400)
    public static let unauthorized = HttpStatusCode(401)
    public static let forbidden = HttpStatusCode(403)
    public static let notFound = HttpStatusCode(404)
    public static let methodNotAllowed = HttpStatusCode(405)
    public static let conflict = HttpStatusCode(409)
    public static let payloadTooLarge = HttpStatusCode(413)
    public static let requestTimeout = HttpStatusCode(408)
    public static let tooManyRequests = HttpStatusCode(429)
    public static let internalServerError = HttpStatusCode(500)
    public static let serviceUnavailable = HttpStatusCode(503)

    /// A human-readable reason phrase for well-known status codes.
    public var reasonPhrase: String {
        switch rawValue {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status \(rawValue)"
        }
    }
}
