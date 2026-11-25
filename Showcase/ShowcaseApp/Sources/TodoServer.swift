// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import Foundation
import SwiftCoreWeb

/// Macro-based controller and Minimal API routes in one pipeline, two authentication schemes, OpenAPI, security headers.
enum TodoServer {
    /// A placeholder for the demo, not a secret. A real app reads these from the Keychain (`SecretStore`).
    static let demoApiKey = "showcase-demo-key"
    static let demoSigningSecret = "showcase-demo-signing-secret"

    static func make() -> WebApplication {
        let builder = WebApplication.createBuilder()
        builder.usePort(8080)
        SecretStore.write(demoSigningSecret, forKey: "jwtSigningSecret")
        builder.services.addSingleton { TodoStore() }

        let app = builder.build()
        app.useExceptionHandler()
        app.useSecurityHeaders()   // CSP `default-src 'self'`: the page's script is a separate file, not inline
        app.useRequestLogging()

        app.useAuthentication(
            .jwt(validate: JwtOptions(hmacSecret: SecretStore.read("jwtSigningSecret"))),
            .custom("apiKey") { request in
                guard let presented = request.headers["X-Api-Key"] else { return nil }
                guard presented == demoApiKey else { throw HttpError(.unauthorized, "Invalid API key") }
                return ClaimsPrincipal(claims: [Claim(type: "sub", value: "service-account")], roles: ["admin"], scheme: "apiKey")
            }
        )
        app.useAuthorization()

        app.mapControllers(TodoController.self)

        let api = app.mapGroup("/api")
        api.mapGet("/health") { _ in "ok" }
        let admin = app.mapGroup("/api/admin").requireAuthorization(.roles(["admin"]))
        admin.mapGet("/stats") { ctx in ["todos": ctx.services.get(TodoStore.self).all().count] }

        app.mapOpenApi(title: "Showcase API", version: "1.0", models: [Todo.openApiSchema])
        app.useVue()
        app.useSpa(root: .bundle("www/todos"))
        return app
    }
}
