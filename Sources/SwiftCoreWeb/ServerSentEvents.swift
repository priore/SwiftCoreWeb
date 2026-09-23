// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// One outgoing Server-Sent Event.
public struct SseEvent: Sendable {
    public var data: String
    public var event: String?
    public var id: String?
    public var retryMilliseconds: Int?

    public init(data: String, event: String? = nil, id: String? = nil, retryMilliseconds: Int? = nil) {
        self.data = data
        self.event = event
        self.id = id
        self.retryMilliseconds = retryMilliseconds
    }

    /// Encodes to the `text/event-stream` wire format (each `data` line
    /// prefixed, blank line terminating the event, per the spec the
    /// browser's `EventSource` expects).
    func encode() -> Data {
        var text = ""
        if let id { text += "id: \(id)\n" }
        if let event { text += "event: \(event)\n" }
        if let retryMilliseconds { text += "retry: \(retryMilliseconds)\n" }
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            text += "data: \(line)\n"
        }
        text += "\n"
        return Data(text.utf8)
    }
}

/// The sink handed to an `app.mapSse(_:_:)` handler, one per connected client.
public struct SseWriter: Sendable {
    let sink: any AsyncByteSink

    /// Sends one event to this client.
    public func send(_ event: SseEvent) async throws {
        try await sink.write(event.encode())
    }

    /// Sends a plain-text event with no name/id (the common case).
    public func send(_ text: String) async throws {
        try await send(SseEvent(data: text))
    }
}

extension WebApplication {
    /// Registers a Server-Sent Events endpoint at `path` (the realtime and OpenAPI contract design), compatible
    /// with the browser's `EventSource` with no client dependencies.
    /// `handler` runs for the lifetime of the connection, writing events via
    /// the given `SseWriter` until it returns or the client disconnects.
    @discardableResult
    public func mapSse(_ path: String, auth: AuthRequirement = .none, summary: String? = nil, _ handler: @escaping @Sendable (SseWriter) async throws -> Void) -> Self {
        routeRegistry.register(method: .get, path: path, auth: auth, summary: summary) { _ in
            var result = Results.stream(contentType: "text/event-stream; charset=utf-8") { sink in
                try await handler(SseWriter(sink: sink))
            }
            result.response.headers["Cache-Control"] = "no-cache"
            result.response.headers["Connection"] = "keep-alive"
            return result
        }
        return self
    }
}
