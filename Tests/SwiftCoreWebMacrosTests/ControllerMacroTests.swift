// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
@testable import SwiftCoreWebMacros
import XCTest

private let testMacros: [String: Macro.Type] = [
    "Controller": ControllerMacro.self,
    "Get": RouteMethodMacro.self,
    "Post": RouteMethodMacro.self,
    "Put": RouteMethodMacro.self,
    "Patch": RouteMethodMacro.self,
    "Delete": RouteMethodMacro.self,
    "Head": RouteMethodMacro.self,
    "Options": RouteMethodMacro.self,
    "Route": RouteMethodMacro.self,
    "ApiModel": ApiModelMacro.self
]

final class ControllerMacroTests: XCTestCase {
    func testSimpleGetRouteExpansion() {
        assertMacroExpansion(
            """
            @Controller("/api/users")
            final class UserController {
                @Get("/{id:int}")
                func getUser(id: Int) async throws -> User {
                    User(id: id)
                }
            }
            """,
            expandedSource: """
            final class UserController {
                func getUser(id: Int) async throws -> User {
                    User(id: id)
                }

                static func registerRoutes(into router: RouteRegistry) {
                    router.register(method: .get, path: "/api/users/{id}", auth: AuthRequirement.none, summary: nil) { ctx in
                        let arg_id = try SwiftCoreWeb.bindRouteValue(ctx.request.routeValues["id"], as: Int.self, parameterName: "id")
                        return try await Self.init().getUser(id: arg_id).toHttpResult()
                    }
                }
            }

            extension UserController: RouteProvider {
            }
            """,
            macros: testMacros
        )
    }

    func testVoidReturnGeneratesNoContentDispatch() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class PingController {
                @Post("/ping")
                func ping() async throws {
                }
            }
            """,
            expandedSource: """
            final class PingController {
                func ping() async throws {
                }

                static func registerRoutes(into router: RouteRegistry) {
                    router.register(method: .post, path: "/api/ping", auth: AuthRequirement.none, summary: nil) { ctx in
                        try await Self.init().ping()
                        return SwiftCoreWeb.voidHttpResult()
                    }
                }
            }

            extension PingController: RouteProvider {
            }
            """,
            macros: testMacros
        )
    }

    func testPlaceholderWithoutMatchingParameterDiagnoses() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class UserController {
                @Get("/{id:int}")
                func getUser() async throws -> User {
                    fatalError()
                }
            }
            """,
            expandedSource: """
            @Controller("/api")
            final class UserController {
                func getUser() async throws -> User {
                    fatalError()
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Route template placeholder has no matching method parameter. '{id}' has no parameter named 'id'.", line: 4, column: 17)
            ],
            macros: ["Get": RouteMethodMacro.self]
        )
    }

    func testUnsupportedParameterTypeDiagnoses() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class UserController {
                @Get("/search")
                func search(filter: [String]) async throws -> User {
                    fatalError()
                }
            }
            """,
            expandedSource: """
            @Controller("/api")
            final class UserController {
                func search(filter: [String]) async throws -> User {
                    fatalError()
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Parameter type is not supported by SwiftCoreWeb's binding rules (HttpContext, LosslessStringConvertible, Decodable, Header<T>, Query<T>, Service<T>, or Form). Parameter 'filter' has type '[String]'.", line: 4, column: 25)
            ],
            macros: ["Get": RouteMethodMacro.self]
        )
    }

    func testNonFinalClassDiagnoses() {
        assertMacroExpansion(
            """
            @Controller("/api")
            class UserController {
                @Get("/users")
                func getUsers() async throws -> [User] {
                    []
                }
            }
            """,
            expandedSource: """
            class UserController {
                @Get("/users")
                func getUsers() async throws -> [User] {
                    []
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "A @Controller type must be a final class, struct, or actor so its generated RouteProvider conformance is Sendable-safe.", line: 1, column: 1)
            ],
            macros: ["Controller": ControllerMacro.self]
        )
    }

    func testDuplicateRouteDiagnoses() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class UserController {
                @Get("/users")
                func listUsers() async throws -> [User] {
                    []
                }

                @Get("/users")
                func listUsersAgain() async throws -> [User] {
                    []
                }
            }
            """,
            expandedSource: """
            final class UserController {
                @Get("/users")
                func listUsers() async throws -> [User] {
                    []
                }

                @Get("/users")
                func listUsersAgain() async throws -> [User] {
                    []
                }

                static func registerRoutes(into router: RouteRegistry) {
                    router.register(method: .get, path: "/api/users", auth: AuthRequirement.none, summary: nil) { ctx in
                        return try await Self.init().listUsers().toHttpResult()
                    }
                }
            }

            extension UserController: RouteProvider {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Duplicate route: this method and HTTP method combination is already registered on this controller. 'GET /api/users'.", line: 8, column: 5)
            ],
            macros: ["Controller": ControllerMacro.self]
        )
    }

    func testInvalidRouteTemplateSyntaxDiagnoses() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class UserController {
                @Get("/{id")
                func getUser(id: Int) async throws -> User {
                    fatalError()
                }
            }
            """,
            expandedSource: """
            @Controller("/api")
            final class UserController {
                func getUser(id: Int) async throws -> User {
                    fatalError()
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Invalid route template syntax. Unterminated '{' in route template '/{id'", line: 2, column: 10)
            ],
            macros: ["Get": RouteMethodMacro.self]
        )
    }

    func testAuthAndSummaryArgumentsForwarded() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class UserController {
                @Get("/me", auth: .authenticated, summary: "Current user")
                func me(ctx: HttpContext) async throws -> User {
                    fatalError()
                }
            }
            """,
            expandedSource: """
            final class UserController {
                func me(ctx: HttpContext) async throws -> User {
                    fatalError()
                }

                static func registerRoutes(into router: RouteRegistry) {
                    router.register(method: .get, path: "/api/me", auth: .authenticated, summary: "Current user") { ctx in
                        let arg_ctx = ctx
                        return try await Self.init().me(ctx: arg_ctx).toHttpResult()
                    }
                }
            }

            extension UserController: RouteProvider {
            }
            """,
            macros: testMacros
        )
    }

    func testUnsupportedReturnTypeDiagnoses() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class UserController {
                @Get("/pair")
                func pair() async throws -> (Int, Int) {
                    fatalError()
                }
            }
            """,
            expandedSource: """
            @Controller("/api")
            final class UserController {
                func pair() async throws -> (Int, Int) {
                    fatalError()
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Return type must be Void, String, an Encodable type, a View, or an HttpResult.", line: 4, column: 33)
            ],
            macros: ["Get": RouteMethodMacro.self]
        )
    }

    func testMarkerOnNonFunctionDiagnoses() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class UserController {
                @Get("/users")
                var users: [User] = []
            }
            """,
            expandedSource: """
            @Controller("/api")
            final class UserController {
                var users: [User] = []
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Route marker macros can only be attached to a method.", line: 3, column: 5)
            ],
            macros: ["Get": RouteMethodMacro.self]
        )
    }

    func testApiModelGeneratesSchema() {
        assertMacroExpansion(
            """
            @ApiModel
            struct User: Codable {
                let id: Int
                let name: String
                let bio: String?
            }
            """,
            expandedSource: """
            struct User: Codable {
                let id: Int
                let name: String
                let bio: String?

                static var openApiSchema: OpenApiSchema {
                    OpenApiSchema(typeName: "User", properties: [
                        "id": OpenApiSchema.Property(type: "integer", isOptional: false),
                        "name": OpenApiSchema.Property(type: "string", isOptional: false),
                        "bio": OpenApiSchema.Property(type: "string", isOptional: true)
                    ])
                }
            }
            """,
            macros: ["ApiModel": ApiModelMacro.self]
        )
    }
}
