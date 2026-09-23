// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// Declares a type as a route controller with the given path prefix.
///
/// Attached to a `final class`, `struct`, or `actor`. Inspects its
/// `@Get`/`@Post`/etc.-annotated methods at compile time and generates
/// `static func registerRoutes(into router: RouteRegistry)` plus conformance
/// to `RouteProvider`. This is the only macro that generates registration
/// code; the method markers below are peer macros that validate their
/// method's signature and route template but emit no code of their own —
/// peer macros cannot add conformances to their enclosing type.
///
/// ```swift
/// @Controller("/api/users")
/// final class UserController {
///     @Get("/{id:int}")
///     func getUser(id: Int) async throws -> User { ... }
/// }
/// // app.mapControllers(UserController.self)
/// ```
@attached(member, names: named(registerRoutes(into:)))
@attached(extension, conformances: RouteProvider)
public macro Controller(_ prefix: String = "") = #externalMacro(module: "SwiftCoreWebMacros", type: "ControllerMacro")

/// Marks a controller method as a `GET` route handler.
///
/// A peer macro: validates the route template against the method's
/// parameters and emits diagnostics (the macro compile-time diagnostics design) but generates no code itself —
/// `@Controller` reads this annotation to generate the actual registration.
@attached(peer)
public macro Get(_ path: String, auth: AuthRequirement = .none, summary: String? = nil) =
    #externalMacro(module: "SwiftCoreWebMacros", type: "RouteMethodMacro")

/// Marks a controller method as a `POST` route handler. See `@Get`.
@attached(peer)
public macro Post(_ path: String, auth: AuthRequirement = .none, summary: String? = nil) =
    #externalMacro(module: "SwiftCoreWebMacros", type: "RouteMethodMacro")

/// Marks a controller method as a `PUT` route handler. See `@Get`.
@attached(peer)
public macro Put(_ path: String, auth: AuthRequirement = .none, summary: String? = nil) =
    #externalMacro(module: "SwiftCoreWebMacros", type: "RouteMethodMacro")

/// Marks a controller method as a `PATCH` route handler. See `@Get`.
@attached(peer)
public macro Patch(_ path: String, auth: AuthRequirement = .none, summary: String? = nil) =
    #externalMacro(module: "SwiftCoreWebMacros", type: "RouteMethodMacro")

/// Marks a controller method as a `DELETE` route handler. See `@Get`.
@attached(peer)
public macro Delete(_ path: String, auth: AuthRequirement = .none, summary: String? = nil) =
    #externalMacro(module: "SwiftCoreWebMacros", type: "RouteMethodMacro")

/// Marks a controller method as a `HEAD` route handler. See `@Get`.
@attached(peer)
public macro Head(_ path: String, auth: AuthRequirement = .none, summary: String? = nil) =
    #externalMacro(module: "SwiftCoreWebMacros", type: "RouteMethodMacro")

/// Marks a controller method as an `OPTIONS` route handler. See `@Get`.
@attached(peer)
public macro Options(_ path: String, auth: AuthRequirement = .none, summary: String? = nil) =
    #externalMacro(module: "SwiftCoreWebMacros", type: "RouteMethodMacro")

/// Marks a controller method as a route handler for an explicit HTTP method,
/// for methods not covered by the named markers above. See `@Get`.
@attached(peer)
public macro Route(_ method: HttpMethod, _ path: String, auth: AuthRequirement = .none, summary: String? = nil) =
    #externalMacro(module: "SwiftCoreWebMacros", type: "RouteMethodMacro")

/// Declares a `Codable` struct's JSON schema for `/openapi.json` generation
/// (the realtime and OpenAPI contract design), computed entirely at compile time from the struct's stored
/// properties — no reflection.
@attached(member)
public macro ApiModel() = #externalMacro(module: "SwiftCoreWebMacros", type: "ApiModelMacro")
