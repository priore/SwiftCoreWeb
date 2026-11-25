// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftCoreWeb

/// Server-Sent Events and a WebSocket echo, used by `www/realtime/index.html`.
enum RealtimeServer {
    static func make() -> WebApplication {
        let builder = WebApplication.createBuilder()
        builder.usePort(8080)
        let app = builder.build()

        app.mapSse("/api/events") { writer in
            for i in 0..<10 {
                try await writer.send("tick \(i)")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        app.mapWebSocket("/ws/echo") { socket in
            for try await message in socket.messages() {
                switch message {
                case .text(let text): try await socket.send("echo: \(text)")
                case .binary(let data): try await socket.send(data)
                }
            }
        }
        app.useSpa(root: .bundle("www/realtime"))
        return app
    }
}
