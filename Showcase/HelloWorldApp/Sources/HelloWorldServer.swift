// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import Foundation
import UIKit
import SwiftCoreWeb
import SwiftCoreWebDashboard

/// Assembles the minimal demo `WebApplication`: the static page in `www/`
/// (bundled as a resource, like `ShowcaseApp/www`) plus one JSON API route,
/// listening on all interfaces so it is reachable at
/// `http://[device-ip]:8080/` from any device on the same network.
enum HelloWorldServer {
    static func makeApplication() -> WebApplication {
        // `createBuilder()` returns the fluent configuration object; nothing
        // is bound to a socket yet — `.build()` below finalizes it into an
        // actual `WebApplication`, and the app only starts listening once
        // `runAsync()` is called from `HelloWorldRootView`.
        let builder = WebApplication.createBuilder()

        builder.usePort(8080)
        // LAN-reachable, not just loopback — the whole point of this sample
        // is "open http://[device-ip] from another machine". Without this
        // call the server would default to binding 127.0.0.1 only, which a
        // WKWebView on the same device can reach but Chrome/Postman on
        // another machine cannot.
        builder.listenOnAllInterfaces()
        // Keeps the device from auto-locking while the server is serving
        // requests in the foreground (see the framework's
        // NetworkWatchdog/LifecycleSupport design). Not required for the demo
        // to work, but avoids the server going quiet mid-test just because
        // the screen dimmed.
        builder.keepDeviceAwake(true)

        // From here on `app` is the live routing/middleware surface: every
        // `.mapGet`/`.use*` call below registers against the same instance.
        let app = builder.build()

        // The one API route this sample exposes. Returning a plain
        // `Encodable` struct (`DeviceNameResponse`) makes the framework
        // serialize it to JSON with a `200 OK` and
        // `Content-Type: application/json` automatically — no manual
        // response building needed (see `HttpResponse.swift`'s
        // `makeHttpResult`). This is the endpoint to hit directly from
        // Chrome or Postman: `http://<device-ip>:8080/api/device-name`.
        app.mapGet("/api/device-name") { _ in
            DeviceNameResponse(
                // `UIDevice.current` is `@MainActor`-isolated (it touches
                // UIKit state), while this route handler runs off the main
                // actor, so the read has to hop via `MainActor.run`.
                deviceName: await MainActor.run { UIDevice.current.name },
                ipAddress: localIPAddress() ?? "unknown"
            )
        }

        // Built-in Vue 3 runtime (the built-in Vue runtime design): serves
        // /_framework/vue.js (the vendored Vue 3 ESM build, MIT licensed,
        // works fully offline — no CDN/npm/Node involved) and
        // /_framework/api.js (a tiny `fetch` wrapper: `api.get(path)` etc.,
        // used by www/index.html below). Must be registered before
        // `useSpa`, though route order does not actually matter here since
        // the paths never collide.
        app.useVue()

        // Serves www/index.html (and any other file placed under www/) from
        // the app bundle, via the framework's static/SPA hosting (the SPA
        // hosting design) — the same mechanism `ShowcaseServer.swift` uses
        // for its Vue build in release mode
        // (`.useSpa(root: .bundle("dist"))`). `useSpa` additionally falls
        // back to index.html for any unmatched `GET` that isn't under
        // `/api`, so client-side routes (if this page ever grows any) keep
        // working on a hard refresh too.
        app.useSpa(root: .bundle("www"))

        // Vue Live Pages demo (see `AI-Workspace/Plans/LIVE_PAGES_PLAN.md`):
        // one text component + one button, proving the round trip —
        // click/type in the browser, Swift on the server updates state, the
        // page re-renders. `useSecurityHeaders()` shows the CSP is
        // compatible (template precompiled server-side, no `unsafe-eval`).
        app.useSecurityHeaders()
        app.usePages(root: .bundle("Views"))
        app.mapPage("/counter", CounterPage.self)

        return app
    }
}

/// Minimal Live Pages demo: a name field and an increment button, nothing
/// else — the full component catalog (select, checkbox, radio, textarea,
/// debounce, session, redirect) lives in `docs/LIVE_PAGES_GUIDE.md`, not here.
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

/// The JSON payload served at `/api/device-name`. Both fields answer the
/// two things you'd want to confirm when testing from an external client:
/// which device answered, and what address you reached it on.
private struct DeviceNameResponse: Encodable {
    let deviceName: String
    let ipAddress: String
}

// `localIPAddress()` moved to `SwiftCoreWebDashboard/NetworkInfo.swift`
// (public there) so the dashboard can reuse it; this showcase just imports it.
