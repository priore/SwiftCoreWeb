// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// An incoming HTTP request, decoupled from SwiftNIO's wire types.
///
/// Handlers never see `HTTPRequestHead` or NIO byte buffers directly; the
/// server engine bridges those into an `HttpRequest` before dispatch.
public struct HttpRequest: Sendable {
    /// The request method.
    public let method: HttpMethod

    /// The request path, without the query string (e.g. `/users/42`).
    public let path: String

    /// Values bound from `{placeholder}` route template segments.
    public let routeValues: [String: String]

    /// Parsed query-string parameters (e.g. `?page=2` → `["page": "2"]`).
    /// A repeated key keeps only the last occurrence; use `queryValues(for:)`
    /// for all occurrences.
    public let query: [String: String]

    /// All values for a repeated query key, in request order.
    public let queryAll: [String: [String]]

    /// Request headers, keyed case-insensitively.
    public let headers: HttpHeaders

    /// The remote peer's address, if known (e.g. `"127.0.0.1"`).
    public let remoteAddress: String?

    /// The full, buffered request body. Populated by the server engine up to
    /// `maxRequestBodySize`; empty for bodyless requests and on `spoolBodyToDisk`
    /// routes (see `bodyFile`).
    public let body: Data

    /// The request body spooled to disk, set instead of `body` (which stays empty) on routes
    /// registered with `spoolBodyToDisk`. A UUID-named file in the uploads directory that is
    /// deleted once the response is produced: read it in the handler, or move it elsewhere
    /// (`FileManager.moveItem`) to keep it. For `multipart/form-data` and url-encoded bodies
    /// use `bindForm(_:)`, which parses it from disk.
    public let bodyFile: URL?

    public init(
        method: HttpMethod,
        path: String,
        routeValues: [String: String] = [:],
        query: [String: String] = [:],
        queryAll: [String: [String]] = [:],
        headers: HttpHeaders = HttpHeaders(),
        remoteAddress: String? = nil,
        body: Data = Data(),
        bodyFile: URL? = nil
    ) {
        self.method = method
        self.path = path
        self.routeValues = routeValues
        self.query = query
        self.queryAll = queryAll
        self.headers = headers
        self.remoteAddress = remoteAddress
        self.body = body
        self.bodyFile = bodyFile
    }

    /// The body as bytes, whether buffered or spooled: a spooled one is read from disk only
    /// if it is at most `limit` bytes, else `413` (it is meant for form fields and JSON, not uploads).
    func smallBody(limit: Int = MultipartFileParser.maxFieldBytes) throws -> Data {
        guard let bodyFile else { return body }
        guard UploadStorage.size(of: bodyFile) <= limit else {
            throw HttpError(.payloadTooLarge, "Request body exceeds \(limit) bytes")
        }
        return try Data(contentsOf: bodyFile)
    }

    /// Decodes the request body as JSON into the given `Decodable` type.
    ///
    /// - Throws: `HttpError(.badRequest)` if the body is empty or not valid
    ///   JSON for the target type.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard !body.isEmpty else {
            throw HttpError(.badRequest, "Request body is empty")
        }
        do {
            return try JSONDecoder().decode(T.self, from: body)
        } catch {
            throw HttpError(.badRequest, "Could not decode request body as \(T.self): \(error)")
        }
    }

    /// The request body decoded as a UTF-8 string, or `nil` if it is not
    /// valid UTF-8.
    public var bodyString: String? {
        String(data: body, encoding: .utf8)
    }
}

/// Case-insensitive HTTP header storage that preserves insertion order and
/// supports repeated header names.
public struct HttpHeaders: Sendable {
    private var storage: [(name: String, value: String)] = []

    public init() {}

    public init(_ pairs: [(String, String)]) {
        for (name, value) in pairs {
            storage.append((name, value))
        }
    }

    /// The first value for `name`, matched case-insensitively.
    public subscript(name: String) -> String? {
        get {
            storage.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        set {
            storage.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let newValue {
                storage.append((name, newValue))
            }
        }
    }

    /// All values for `name`, matched case-insensitively, in request order.
    public func values(for name: String) -> [String] {
        storage.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// Appends a header value without removing existing values for `name`.
    public mutating func add(_ name: String, _ value: String) {
        storage.append((name, value))
    }

    /// All header pairs, in insertion order.
    public var all: [(name: String, value: String)] { storage }
}
