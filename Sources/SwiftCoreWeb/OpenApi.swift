// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// Converts a route template's `{id:int}`/`{page?}`/`{*path}` placeholders
/// into the plain `{id}` form OpenAPI 3 path templates use.
private func openApiPath(from raw: String) -> String {
    var result = ""
    var inBraces = false
    var name = ""
    for char in raw {
        if char == "{" { inBraces = true; name = ""; continue }
        if char == "}" {
            inBraces = false
            var cleaned = name
            if cleaned.hasPrefix("*") { cleaned.removeFirst() }
            if cleaned.hasSuffix("?") { cleaned.removeLast() }
            if let colon = cleaned.firstIndex(of: ":") { cleaned = String(cleaned[cleaned.startIndex..<colon]) }
            result += "{\(cleaned)}"
            continue
        }
        if inBraces { name.append(char) } else { result.append(char) }
    }
    return result
}

/// Extracts `{name}` path-parameter names from an already-cleaned OpenAPI path.
private func pathParameterNames(_ path: String) -> [String] {
    var names: [String] = []
    var current = ""
    var inBraces = false
    for char in path {
        if char == "{" { inBraces = true; current = ""; continue }
        if char == "}" { inBraces = false; names.append(current); continue }
        if inBraces { current.append(char) }
    }
    return names
}

/// Builds the `/openapi.json` document from the router's compile-time route
/// metadata (the realtime and OpenAPI contract design): methods, paths, parameters, auth, and summaries. DTO
/// schemas for request/response bodies come from `@ApiModel`-generated
/// `OpenApiSchema` values, registered explicitly via `mapOpenApi(models:)`
/// — there is no reflection-based type discovery.
enum OpenApiDocument {
    static func build(routes: [Route], title: String, version: String, models: [OpenApiSchema]) -> [String: Any] {
        var paths: [String: [String: Any]] = [:]

        for route in routes {
            let cleanPath = openApiPath(from: route.template.raw)
            var operation: [String: Any] = [:]
            if let summary = route.summary { operation["summary"] = summary }

            let paramNames = pathParameterNames(cleanPath)
            if !paramNames.isEmpty {
                operation["parameters"] = paramNames.map { name -> [String: Any] in
                    ["name": name, "in": "path", "required": true, "schema": ["type": "string"]]
                }
            }

            switch route.auth {
            case .none:
                break
            default:
                operation["security"] = [["bearerAuth": [] as [String]]]
            }

            operation["responses"] = ["200": ["description": "Successful response"]]

            var pathItem = paths[cleanPath] ?? [:]
            pathItem[route.method.rawValue.lowercased()] = operation
            paths[cleanPath] = pathItem
        }

        var schemas: [String: Any] = [:]
        for model in models {
            var properties: [String: Any] = [:]
            var required: [String] = []
            for (name, property) in model.properties {
                properties[name] = ["type": property.type]
                if !property.isOptional { required.append(name) }
            }
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required.sorted() }
            schemas[model.typeName] = schema
        }

        return [
            "openapi": "3.0.3",
            "info": ["title": title, "version": version],
            "paths": paths,
            "components": [
                "schemas": schemas,
                "securitySchemes": ["bearerAuth": ["type": "http", "scheme": "bearer", "bearerFormat": "JWT"]]
            ]
        ]
    }
}

extension WebApplication {
    /// Serves `/openapi.json`, built from compile-time route metadata, and
    /// (in `.development` only) a minimal `/__routes` HTML list for humans —
    /// a dev UI for the JS frontend to consult, not TypeScript generation.
    ///
    /// `models` lists the `@ApiModel` types whose `openApiSchema` should
    /// appear under `components.schemas`; registration is explicit, per the
    /// framework's zero-reflection rule.
    @discardableResult
    public func mapOpenApi(title: String = "API", version: String = "1.0", models: [OpenApiSchema] = []) -> Self {
        let isDevelopment = environment == .development
        routeRegistry.register(method: .get, path: "/openapi.json", auth: .none, summary: "OpenAPI 3 document") { [weak self] _ in
            guard let self else { return Results.notFound() }
            let document = OpenApiDocument.build(routes: self.routeRegistry.allRoutes, title: title, version: version, models: models)
            guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) else {
                return Results.problem(status: .internalServerError, detail: "Failed to build OpenAPI document")
            }
            var headers = HttpHeaders()
            headers["Content-Type"] = "application/json; charset=utf-8"
            return HttpResult(HttpResponse(status: .ok, headers: headers, body: .json(data)))
        }

        if isDevelopment {
            routeRegistry.register(method: .get, path: "/__routes", auth: .none, summary: nil) { [weak self] _ in
                guard let self else { return Results.notFound() }
                let rows = self.routeRegistry.allRoutes
                    .sorted { $0.template.raw < $1.template.raw }
                    .map { route -> String in
                        let authLabel: String
                        switch route.auth {
                        case .none: authLabel = "public"
                        case .authenticated: authLabel = "authenticated"
                        case .roles(let roles): authLabel = "roles: \(roles.joined(separator: ", "))"
                        case .policy(let name): authLabel = "policy: \(name)"
                        case .scheme(let name): authLabel = "scheme: \(name)"
                        }
                        let summary = route.summary.map { " — \($0)" } ?? ""
                        return "<tr><td>\(route.method.rawValue)</td><td>\(route.template.raw)</td><td>\(authLabel)</td><td>\(summary)</td></tr>"
                    }
                    .joined()
                let html = """
                <!DOCTYPE html><html><head><meta charset="utf-8"><title>Routes</title></head>
                <body><h1>SwiftCoreWeb — Registered Routes</h1>
                <table border="1" cellpadding="6"><tr><th>Method</th><th>Path</th><th>Auth</th><th>Summary</th></tr>\(rows)</table>
                <p><a href="/openapi.json">/openapi.json</a></p>
                </body></html>
                """
                return html
            }
        }

        return self
    }
}
