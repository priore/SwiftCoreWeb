// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import UIKit
import SwiftCoreWeb
import SwiftCoreWebDashboard

/// A static Vue page plus one JSON route, reachable from the LAN at `http://<device-ip>:8080/`.
enum HelloServer {
    static func make() -> WebApplication {
        let builder = WebApplication.createBuilder()
        builder.usePort(8080)
        builder.listenOnAllInterfaces()
        builder.keepDeviceAwake(true)
        let app = builder.build()

        app.mapGet("/api/device-name") { _ in
            DeviceNameResponse(
                // `UIDevice.current` is main-actor isolated; route handlers run off it.
                deviceName: await MainActor.run { UIDevice.current.name },
                ipAddress: localIPAddress() ?? "unknown"
            )
        }
        app.useVue()                         // /_framework/vue.js and /_framework/api.js, no CDN, no build step
        app.useSpa(root: .bundle("www/hello")) // static hosting with ETag/Range/MIME types
        return app
    }
}

private struct DeviceNameResponse: Encodable {
    let deviceName: String
    let ipAddress: String
}
