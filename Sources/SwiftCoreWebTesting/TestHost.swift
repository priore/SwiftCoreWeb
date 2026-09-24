// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import SwiftCoreWeb

/// An in-memory response returned by `TestHost`, decoupled from NIO wire
/// types just like the public `HttpResponse` it wraps.
public struct TestResponse: Sendable {
    /// The HTTP status code.
    public let status: Int
    /// Response headers, keyed case-insensitively.
    public let headers: HttpHeaders
    /// The raw response body bytes.
    public let body: Data

    public init(status: Int, headers: HttpHeaders, body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The body decoded as a UTF-8 string, or `nil` if it is not valid UTF-8.
    public var bodyString: String? { String(data: body, encoding: .utf8) }

    /// Decodes the body as JSON into the given `Decodable` type.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: body)
    }
}

/// Runs the full SwiftCoreWeb pipeline in memory, with no sockets, per the testing support design.
///
/// Built on NIO's `NIOAsyncTestingChannel`: every request is written as
/// real HTTP/1.1 wire bytes and decoded back with the same
/// `HTTPRequestDecoder`/`HTTPResponseEncoder` pair the production
/// `ServerEngine` installs on every connection, then dispatched through the
/// identical `RequestDispatcher` (routing, middleware pipeline,
/// authentication, authorization, handler). Only the transport differs — an
/// in-memory `NIOAsyncTestingChannel` instead of a bound
/// `NIOTSListenerBootstrap` socket — so a passing test exercises the exact
/// same handler chain as production.
///
/// ```swift
/// let app = WebApplication.createBuilder().build()
/// app.mapGet("/api/users/{id}") { ctx in User(id: try bindRouteValue(ctx.request.routeValues["id"], as: Int.self, parameterName: "id")) }
/// let host = try await TestHost(app)
/// let res = try await host.get("/api/users/1")
/// let user = try res.decode(User.self)
/// ```
public final class TestHost: @unchecked Sendable {
    private let dispatcher: RequestDispatcher
    private let channel: NIOAsyncTestingChannel

    /// Builds a test host for `app`, wiring up the same request-decoding /
    /// response-encoding pipeline the production engine uses, backed by an
    /// in-memory channel. Freezes `app`'s router and middleware pipeline,
    /// exactly as `runAsync()` would.
    public init(_ app: WebApplication) async throws {
        self.dispatcher = app.buildDispatcher()
        let channel = NIOAsyncTestingChannel()
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPRequestDecoder()))
            try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())
        }.get()
        try await channel.connect(to: .init(unixDomainSocketPath: "/test")).get()
        self.channel = channel
    }

    /// Sends a request through the full pipeline and returns the response.
    ///
    /// The request is encoded as real HTTP/1.1 bytes, written into the
    /// testing channel's inbound side, decoded by `HTTPRequestDecoder`
    /// exactly as the production connection loop decodes wire bytes, then
    /// handed to the same `RequestDispatcher.dispatch(_:)` the server engine
    /// calls. The dispatcher's `HttpResponse` is encoded back to wire bytes
    /// by `HTTPResponseEncoder` and parsed into a `TestResponse`.
    public func send(
        _ method: HttpMethod,
        _ path: String,
        headers: [(String, String)] = [],
        body: Data = Data()
    ) async throws -> TestResponse {
        var httpHeaders = HTTPHeaders()
        for (name, value) in headers {
            httpHeaders.add(name: name, value: value)
        }
        if !body.isEmpty, httpHeaders["Content-Length"].isEmpty {
            httpHeaders.add(name: "Content-Length", value: "\(body.count)")
        }

        var requestHead = HTTPRequestHead(version: .http1_1, method: .init(rawValue: method.rawValue), uri: path)
        requestHead.headers = httpHeaders

        var wireBuffer = ByteBufferAllocator().buffer(capacity: 256 + body.count)
        wireBuffer.writeString("\(requestHead.method.rawValue) \(path) HTTP/1.1\r\n")
        for (name, value) in httpHeaders {
            wireBuffer.writeString("\(name): \(value)\r\n")
        }
        wireBuffer.writeString("\r\n")
        if !body.isEmpty {
            wireBuffer.writeBytes(body)
        }

        try await channel.writeInbound(wireBuffer)

        var requestHeadDecoded: HTTPRequestHead?
        var bodyBuffer = ByteBuffer()
        while let part = try await channel.readInbound(as: HTTPServerRequestPart.self) {
            switch part {
            case .head(let head):
                requestHeadDecoded = head
            case .body(var chunk):
                bodyBuffer.writeBuffer(&chunk)
            case .end:
                break
            }
        }
        guard let head = requestHeadDecoded else {
            throw TestHostError.decodingFailed
        }

        let (path0, rawQuery) = splitPathAndQuery(head.uri)
        let (query, queryAll) = parseQueryString(rawQuery)
        var requestHeaders = HttpHeaders()
        for (name, value) in head.headers {
            requestHeaders.add(name, value)
        }

        let request = HttpRequest(
            method: HttpMethod(rawValue: head.method.rawValue) ?? method,
            path: path0,
            query: query,
            queryAll: queryAll,
            headers: requestHeaders,
            remoteAddress: "127.0.0.1",
            body: bodyBuffer.readData(length: bodyBuffer.readableBytes) ?? Data()
        )

        let response = await dispatcher.dispatch(request)
        return try await encode(response, method: method)
    }

    /// Encodes `response` through the production `HTTPResponseEncoder`
    /// installed on the testing channel, then decodes the resulting wire
    /// bytes back into a `TestResponse`.
    private func encode(_ response: HttpResponse, method: HttpMethod) async throws -> TestResponse {
        var headers = HTTPHeaders()
        for (name, value) in response.headers.all {
            headers.add(name: name, value: value)
        }

        var bodyData = Data()
        switch response.body {
        case .empty:
            headers.replaceOrAdd(name: "Content-Length", value: "0")
        case .text(let string):
            bodyData = Data(string.utf8)
            headers.replaceOrAdd(name: "Content-Length", value: "\(bodyData.count)")
        case .json(let data):
            bodyData = data
            headers.replaceOrAdd(name: "Content-Length", value: "\(bodyData.count)")
        case .data(let data):
            bodyData = data
            headers.replaceOrAdd(name: "Content-Length", value: "\(bodyData.count)")
        case .file(let path, let range):
            bodyData = try readFile(at: path, range: range)
            headers.replaceOrAdd(name: "Content-Length", value: "\(bodyData.count)")
        case .stream(let writer):
            let sink = CollectingByteSink()
            try await writer(sink)
            bodyData = await sink.collectedData()
            headers.replaceOrAdd(name: "Content-Length", value: "\(bodyData.count)")
        }

        if method == .head {
            bodyData = Data()
        }

        return TestResponse(
            status: response.status.rawValue,
            headers: {
                var httpHeaders = HttpHeaders()
                for (name, value) in headers {
                    httpHeaders.add(name, value)
                }
                return httpHeaders
            }(),
            body: bodyData
        )
    }

    private func readFile(at path: String, range: ClosedRange<Int>?) throws -> Data {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let range else { return data }
        let lower = min(range.lowerBound, data.count)
        let upper = min(range.upperBound + 1, data.count)
        guard lower < upper else { return Data() }
        return data.subdata(in: lower..<upper)
    }

    // MARK: - Ergonomic HTTP method helpers

    /// Sends a `GET` request.
    @discardableResult
    public func get(_ path: String, headers: [(String, String)] = []) async throws -> TestResponse {
        try await send(.get, path, headers: headers)
    }

    /// Sends a `POST` request with an optional JSON-encoded body.
    @discardableResult
    public func post<T: Encodable>(_ path: String, json body: T, headers: [(String, String)] = []) async throws -> TestResponse {
        try await send(.post, path, headers: withJsonContentType(headers), body: try JSONEncoder().encode(body))
    }

    /// Sends a `POST` request with a raw body.
    @discardableResult
    public func post(_ path: String, body: Data = Data(), headers: [(String, String)] = []) async throws -> TestResponse {
        try await send(.post, path, headers: headers, body: body)
    }

    /// Sends a `PUT` request with an optional JSON-encoded body.
    @discardableResult
    public func put<T: Encodable>(_ path: String, json body: T, headers: [(String, String)] = []) async throws -> TestResponse {
        try await send(.put, path, headers: withJsonContentType(headers), body: try JSONEncoder().encode(body))
    }

    /// Sends a `PUT` request with a raw body.
    @discardableResult
    public func put(_ path: String, body: Data = Data(), headers: [(String, String)] = []) async throws -> TestResponse {
        try await send(.put, path, headers: headers, body: body)
    }

    /// Sends a `PATCH` request with an optional JSON-encoded body.
    @discardableResult
    public func patch<T: Encodable>(_ path: String, json body: T, headers: [(String, String)] = []) async throws -> TestResponse {
        try await send(.patch, path, headers: withJsonContentType(headers), body: try JSONEncoder().encode(body))
    }

    /// Sends a `PATCH` request with a raw body.
    @discardableResult
    public func patch(_ path: String, body: Data = Data(), headers: [(String, String)] = []) async throws -> TestResponse {
        try await send(.patch, path, headers: headers, body: body)
    }

    /// Sends a `DELETE` request.
    @discardableResult
    public func delete(_ path: String, headers: [(String, String)] = []) async throws -> TestResponse {
        try await send(.delete, path, headers: headers)
    }

    /// Sends a `HEAD` request.
    @discardableResult
    public func head(_ path: String, headers: [(String, String)] = []) async throws -> TestResponse {
        try await send(.head, path, headers: headers)
    }

    /// Sends an `OPTIONS` request.
    @discardableResult
    public func options(_ path: String, headers: [(String, String)] = []) async throws -> TestResponse {
        try await send(.options, path, headers: headers)
    }

    private func withJsonContentType(_ headers: [(String, String)]) -> [(String, String)] {
        guard !headers.contains(where: { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }) else {
            return headers
        }
        return headers + [("Content-Type", "application/json")]
    }
}

enum TestHostError: Error {
    case decodingFailed
}

/// A stream-writer sink that collects every chunk into memory, for
/// `TestHost`'s in-memory response encoding. Not for production use.
private actor CollectingByteSink: AsyncByteSink {
    private var buffer = Data()

    func write(_ chunk: Data) async throws {
        buffer.append(chunk)
    }

    func collectedData() -> Data { buffer }
}
