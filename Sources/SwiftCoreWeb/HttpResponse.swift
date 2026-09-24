// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// A body writer describing how an `HttpResponse` body is produced.
///
/// The server engine consumes this to write the wire response; handlers
/// never touch NIO byte buffers directly.
public enum HttpResponseBody: Sendable {
    /// No body.
    case empty
    /// Raw bytes, sent as-is.
    case data(Data)
    /// UTF-8 text; the engine sets `Content-Length` from its byte count.
    case text(String)
    /// Pre-encoded JSON bytes.
    case json(Data)
    /// A file on disk, streamed rather than loaded fully into memory.
    /// Supports `Range` requests when `HttpResponse.acceptsRanges` is set;
    /// `range` (start...end, inclusive byte offsets) is set by the static
    /// file middleware after parsing the request's `Range` header.
    case file(path: String, range: ClosedRange<Int>? = nil)
    /// An application-provided async byte stream, for large or generated
    /// payloads that should not be buffered in full.
    case stream(@Sendable (any AsyncByteSink) async throws -> Void)

    /// Known byte size for the metrics/logging counters (the on-device
    /// dashboard design). `.file` and `.stream` report 0 — their size isn't
    /// known without reading/streaming, which this counter isn't worth doing.
    var byteCount: Int {
        switch self {
        case .empty, .file, .stream: return 0
        case .data(let data): return data.count
        case .text(let string): return string.utf8.count
        case .json(let data): return data.count
        }
    }
}

/// A sink handlers write streamed response bytes into.
public protocol AsyncByteSink: Sendable {
    func write(_ chunk: Data) async throws
}

/// An outgoing HTTP response.
///
/// Built by handlers directly or via `HttpResult`/`Results` helpers, and
/// consumed by the server engine to write the wire response.
public struct HttpResponse: Sendable {
    public var status: HttpStatusCode
    public var headers: HttpHeaders
    public var body: HttpResponseBody

    /// Whether this response supports byte-range requests (set for file
    /// responses that permit `206 Partial Content`).
    public var acceptsRanges: Bool

    public init(
        status: HttpStatusCode = .ok,
        headers: HttpHeaders = HttpHeaders(),
        body: HttpResponseBody = .empty,
        acceptsRanges: Bool = false
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.acceptsRanges = acceptsRanges
    }
}

/// The return type of a Minimal API or `@Controller` handler.
///
/// Handlers may return `Void`, `String`, any `Encodable`, a `View`, or an
/// `HttpResult` built via the `Results` factory. All conversions funnel
/// through `HttpResult` so the engine has one code path for producing the
/// wire response.
public struct HttpResult: Sendable {
    public var response: HttpResponse

    public init(_ response: HttpResponse) {
        self.response = response
    }
}

/// Convertible to an `HttpResult`. Conformances are provided for the
/// built-in handler return types listed in the routing specification.
public protocol HttpResultConvertible: Sendable {
    func toHttpResult() throws -> HttpResult
}

extension HttpResult: HttpResultConvertible {
    public func toHttpResult() throws -> HttpResult { self }
}

/// The `HttpResult` a `Void`-returning handler produces (`204 No Content`).
///
/// `Void` cannot itself conform to `HttpResultConvertible` — it is the empty
/// tuple, not a nominal type — so generated dispatch code (the return-type conversion rules: `@Controller`
/// and the closure `map*` overloads) calls this directly for handlers
/// declared to return nothing.
public func voidHttpResult() -> HttpResult {
    HttpResult(HttpResponse(status: .noContent))
}

extension String: HttpResultConvertible {
    public func toHttpResult() throws -> HttpResult {
        var headers = HttpHeaders()
        headers["Content-Type"] = "text/plain; charset=utf-8"
        return HttpResult(HttpResponse(status: .ok, headers: headers, body: .text(self)))
    }
}

/// the return-type conversion rules: any other `Encodable` handler return value serializes to `200 OK`
/// JSON. `String` and `HttpResult` are handled by their own, more specific
/// conformances above; this blanket conformance covers every plain model
/// type (a `struct`/`enum` DTO) without it declaring `HttpResultConvertible`
/// by hand.
/// Converts any handler return value to its `HttpResult` per the return-type conversion rules:
/// `HttpResultConvertible` types (`HttpResult`, `String`, `View`) use their
/// own conformance; every other `Encodable` value serializes to `200 OK`
/// JSON. A plain `Encodable` DTO cannot itself be made to retroactively
/// conform to `HttpResultConvertible` (Swift has no blanket-conformance
/// syntax for "every `Encodable & Sendable` type"), so this dispatches at
/// the one call site the `map*` closures all funnel through instead.
func makeHttpResult(_ value: some Sendable) throws -> HttpResult {
    if let convertible = value as? HttpResultConvertible {
        return try convertible.toHttpResult()
    }
    if let encodable = value as? Encodable {
        var headers = HttpHeaders()
        headers["Content-Type"] = "application/json; charset=utf-8"
        let data = try JSONEncoderBox.encode(encodable)
        return HttpResult(HttpResponse(status: .ok, headers: headers, body: .json(data)))
    }
    preconditionFailure("SwiftCoreWeb: handler return type must be Void, an HttpResultConvertible, or Encodable.")
}

/// `JSONEncoder.encode` is generic over a concrete `Encodable` type, but
/// `makeHttpResult` only has an existential `any Encodable` — this opens it
/// back up to a concrete type so encoding still works.
private enum JSONEncoderBox {
    static func encode(_ value: any Encodable) throws -> Data {
        try JSONEncoder().encode(AnyEncodable(value))
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}



/// Factory namespace for building `HttpResult` values, mirroring
/// .NET Minimal APIs' `Results` type.
public enum Results {
    public static func ok<T: Encodable>(_ value: T) -> HttpResult {
        json(value, status: .ok)
    }

    public static func ok() -> HttpResult {
        HttpResult(HttpResponse(status: .ok))
    }

    public static func created<T: Encodable>(location: String, _ value: T) -> HttpResult {
        var result = json(value, status: .created)
        result.response.headers["Location"] = location
        return result
    }

    public static func noContent() -> HttpResult {
        HttpResult(HttpResponse(status: .noContent))
    }

    public static func badRequest<T: Encodable>(_ value: T) -> HttpResult {
        json(value, status: .badRequest)
    }

    public static func badRequest(_ detail: String? = nil) -> HttpResult {
        problem(status: .badRequest, detail: detail)
    }

    public static func notFound() -> HttpResult {
        problem(status: .notFound, detail: nil)
    }

    public static func unauthorized() -> HttpResult {
        problem(status: .unauthorized, detail: nil)
    }

    public static func forbidden() -> HttpResult {
        problem(status: .forbidden, detail: nil)
    }

    public static func redirect(_ location: String, permanent: Bool = false) -> HttpResult {
        var headers = HttpHeaders()
        headers["Location"] = location
        return HttpResult(HttpResponse(
            status: HttpStatusCode(permanent ? 301 : 302),
            headers: headers,
            body: .empty
        ))
    }

    public static func file(_ path: String, contentType: String? = nil) -> HttpResult {
        var headers = HttpHeaders()
        if let contentType {
            headers["Content-Type"] = contentType
        }
        return HttpResult(HttpResponse(
            status: .ok,
            headers: headers,
            body: .file(path: path, range: nil),
            acceptsRanges: true
        ))
    }

    public static func stream(
        contentType: String = "application/octet-stream",
        _ writer: @escaping @Sendable (any AsyncByteSink) async throws -> Void
    ) -> HttpResult {
        var headers = HttpHeaders()
        headers["Content-Type"] = contentType
        return HttpResult(HttpResponse(status: .ok, headers: headers, body: .stream(writer)))
    }

    /// Builds a JSON `HttpResult` for any `Encodable` value.
    public static func json<T: Encodable>(_ value: T, status: HttpStatusCode = .ok) -> HttpResult {
        var headers = HttpHeaders()
        headers["Content-Type"] = "application/json; charset=utf-8"
        guard let data = try? JSONEncoder().encode(value) else {
            return problem(status: .internalServerError, detail: "Failed to encode response body")
        }
        return HttpResult(HttpResponse(status: status, headers: headers, body: .json(data)))
    }

    /// Builds an RFC 9457 ProblemDetails JSON result.
    public static func problem(status: HttpStatusCode, detail: String?) -> HttpResult {
        let problem = ProblemDetails(title: status.reasonPhrase, status: status.rawValue, detail: detail)
        return json(problem, status: status)
    }
}

/// Any `Encodable` value returned from a handler becomes a `200 OK` JSON
/// response per the return-type conversion rules, unless a more specific conformance (`String`,
/// `HttpResult`) applies. Handler dispatch (generated by `@Controller` and
/// the closure `map*` overloads) picks the `String`/`HttpResult` overload
/// when available and falls back to this one otherwise.
extension Encodable where Self: Sendable {
    public func toHttpResult() throws -> HttpResult {
        Results.ok(self)
    }
}
