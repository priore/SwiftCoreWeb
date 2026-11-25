// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftCoreWeb

/// A server-driven page: the state lives in Swift, the template is `Views/counter.html`, events come back as `$swift(...)`.
enum LivePagesServer {
    static func make() -> WebApplication {
        let builder = WebApplication.createBuilder()
        builder.usePort(8080)
        let app = builder.build()
        app.useSecurityHeaders()   // the template is compiled on the server, so the CSP needs no `unsafe-eval`
        app.usePages(root: .bundle("Views"))
        app.mapPage("/counter", CounterPage.self)
        return app
    }
}

struct CounterPage: Page {
    static let template = "counter.html"
    static let title = "Counter"

    struct Form: Codable, Sendable {
        var name = ""
    }
    var form = Form()
    var count = 0

    mutating func onEvent(_ event: String, _ ctx: PageContext) async throws -> PageAction {
        if event == "increment" { count += 1 }
        return .render
    }
}
