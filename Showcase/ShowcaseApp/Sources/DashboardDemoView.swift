// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftUI
import SwiftCoreWeb
import SwiftCoreWebDashboard

/// The on-device dashboard (CPU, memory, battery, request metrics) for a small server started with the screen.
struct DashboardDemoView: SwiftUI.View {
    var body: some SwiftUI.View {
        ServerGate(key: "web", make: { (DashboardServer.make(), ()) }) { app, _ in
            SwiftCoreWebDashboardView(app: app)
        }
    }
}

enum DashboardServer {
    static func make() -> WebApplication {
        let builder = WebApplication.createBuilder()
        builder.usePort(8080)
        builder.keepDeviceAwake(true)
        let app = builder.build()
        app.mapGet("/api/health") { _ in "ok" }
        return app
    }
}
