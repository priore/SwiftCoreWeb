// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// Why a WebSocket's `messages()` ended with an error instead of ending cleanly.
public enum WebSocketError: Error, Sendable, Equatable {
    /// The handler fell too far behind: more messages were waiting than the server keeps, so the connection was closed
    /// with 1008 (policy violation). Messages that were already queued are delivered before this error.
    case slowConsumer
}
