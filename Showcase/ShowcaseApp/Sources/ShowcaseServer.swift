// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//
// Showcase sample. Not part of the SwiftCoreWeb library targets — see
// Showcase/README.md for how to wire these files into an Xcode app target.

import Foundation
import SwiftCoreWeb

/// Assembles the demo `WebApplication`: controllers (macro-based) and
/// closure Minimal API routes side by side, two authentication schemes,
/// CORS/security/logging middleware, static/SPA hosting for the bundled
/// Vue frontend, and a WebSocket + SSE endpoint. Called once from
/// `ShowcaseApp.init()`.
enum ShowcaseServer {
    /// The demo API key accepted by the `apiKey` custom scheme (the pluggable authentication schemes design). A real
    /// app would read this from the Keychain via `SecretStore`, exactly like
    /// the JWT secret below — hardcoded here only for a copy-pasteable demo.
    private static let demoApiKey = "showcase-demo-key"

    static func makeApplication() -> WebApplication {
        let builder = WebApplication.createBuilder()

        // Secure by default: loopback only. The WKWebView in this same app
        // talks to 127.0.0.1, so no LAN exposure is needed for Mode C. Mode A
        // (Vite on the Mac) instead calls `listenOnAllInterfaces()` — see
        // Showcase/README.md.
        builder.usePort(8080)

        // Keep-awake is ON by default (the concurrency/lifecycle/network watchdog design); shown explicitly here for the
        // showcase, so the device never auto-locks while serving.
        builder.keepDeviceAwake(true)

        // Demo JWT secret. Production apps must never hardcode this — write
        // it once with `SecretStore.write(_:forKey:)` during onboarding and
        // read it back with `SecretStore.read(_:)`, exactly as `.useHttps`
        // reads its `.p12` password from the Keychain.
        SecretStore.write("showcase-demo-signing-secret", forKey: "jwtSigningSecret")

        builder.services.addSingleton { TodoStore() }

        let app = builder.build()

        app.useExceptionHandler()
        app.useSecurityHeaders()
        app.useCors { options in
            options.allowedOrigins = ["http://localhost:5173", "http://*.local:5173"]
        }
        app.useRequestLogging()

        // Two authentication schemes registered side by side (the pluggable authentication schemes design): JWT
        // Bearer tokens, and a custom `apiKey` header scheme for
        // machine-to-machine calls. Either one satisfies `auth: .authenticated`;
        // `auth: .scheme("apiKey")` on a route would require that one specifically.
        app.useAuthentication(
            .jwt(validate: JwtOptions(hmacSecret: SecretStore.read("jwtSigningSecret"))),
            .custom("apiKey") { request in
                guard let presented = request.headers["X-Api-Key"] else { return nil }
                guard presented == demoApiKey else {
                    throw HttpError(.unauthorized, "Invalid API key")
                }
                return ClaimsPrincipal(claims: [Claim(type: "sub", value: "service-account")], roles: ["admin"], scheme: "apiKey")
            }
        )
        app.useAuthorization()

        // Macro-based controller (the pluggable authentication schemes design).
        app.mapControllers(TodoController.self)

        // Minimal API closure routes (the Minimal API closure routing design), sharing the same DI-resolved
        // store and the same auth/authorization middleware as the controller
        // above — both routing styles run through one pipeline.
        registerMinimalApiRoutes(on: app)

        app.mapOpenApi(title: "Showcase API", version: "1.0", models: [Todo.openApiSchema])
        app.mapSse("/api/events") { writer in
            for i in 0..<5 {
                try await writer.send("tick \(i)")
                try await Task.sleep(for: .seconds(1))
            }
        }
        app.mapWebSocket("/ws/echo") { socket in
            for try await message in socket.messages() {
                switch message {
                case .text(let text):
                    try await socket.send("echo: \(text)")
                case .binary(let data):
                    try await socket.send(data)
                }
            }
        }

        // Serves the built-in Vue 3 runtime for zero-build pages (the built-in Vue runtime design), then
        // the bundled Vue `dist/` build with SPA fallback (the SPA hosting design). In DEBUG,
        // `useDevDeploy` additionally opens the Mode B on-device deploy path
        // documented in Showcase/README.md; it does not exist in release
        // builds at all.
        app.useVue()
        #if DEBUG
        app.useDevDeploy(root: .documents("www"))
        app.useSpa(root: .documents("www"))
        #else
        app.useSpa(root: .bundle("dist"))
        #endif

        return app
    }

    /// Route groups and closure-based Minimal API routes (the Minimal API closure routing design), registered
    /// alongside `TodoController`'s macro-based routes above.
    private static func registerMinimalApiRoutes(on app: WebApplication) {
        let api = app.mapGroup("/api")

        api.mapGet("/health") { _ in "ok" }

        let admin = app.mapGroup("/api/admin").requireAuthorization(.roles(["admin"]))
        admin.mapGet("/stats") { ctx in
            ["todos": ctx.services.get(TodoStore.self).all().count]
        }
    }
}
