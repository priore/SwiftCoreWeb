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
                    router.register(method: .get, path: "/api/users/{id:int}", auth: AuthRequirement.none, summary: nil) { ctx in
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

    func testFormParameterBindsThroughContext() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class UploadController {
                @Post("/upload")
                func upload(form: Form) async throws {
                }
            }
            """,
            expandedSource: """
            final class UploadController {
                func upload(form: Form) async throws {
                }

                static func registerRoutes(into router: RouteRegistry) {
                    router.register(method: .post, path: "/api/upload", auth: AuthRequirement.none, summary: nil) { ctx in
                        let arg_form = try SwiftCoreWeb.bindForm(ctx)
                        try await Self.init().upload(form: arg_form)
                        return SwiftCoreWeb.voidHttpResult()
                    }
                }
            }

            extension UploadController: RouteProvider {
            }
            """,
            macros: testMacros
        )
    }

    func testMaxRequestBodySizeArgumentIsPassedToRegistration() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class BigController {
                @Post("/big", maxRequestBodySize: 5_000_000)
                func big() async throws {
                }
            }
            """,
            expandedSource: """
            final class BigController {
                func big() async throws {
                }

                static func registerRoutes(into router: RouteRegistry) {
                    router.register(method: .post, path: "/api/big", auth: AuthRequirement.none, summary: nil, maxBodySize: 5_000_000) { ctx in
                        try await Self.init().big()
                        return SwiftCoreWeb.voidHttpResult()
                    }
                }
            }

            extension BigController: RouteProvider {
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

    func testUnconstrainedPlaceholderConvertsToDeclaredType() {
        assertMacroExpansion(
            """
            @Controller("/api/users")
            final class UserController {
                @Get("/{id}")
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

    func testConstraintTypeMismatchDiagnoses() {
        assertMacroExpansion(
            """
            final class UserController {
                @Get("/{id:int}")
                func getUser(id: UUID) async throws -> User {
                    fatalError()
                }
            }
            """,
            expandedSource: """
            final class UserController {
                func getUser(id: UUID) async throws -> User {
                    fatalError()
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Route constraint does not match the type of the parameter that binds the placeholder. Constraint ':int' on '{id}' requires Int, but the parameter is 'UUID'.", line: 3, column: 22)
            ],
            macros: ["Get": RouteMethodMacro.self]
        )
    }

    func testEquivalentPlaceholdersAreDuplicates() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class UserController {
                @Get("/users/{id}")
                func byId(id: String) async throws -> String { id }

                @Get("/users/{name}")
                func byName(name: String) async throws -> String { name }
            }
            """,
            expandedSource: """
            final class UserController {
                @Get("/users/{id}")
                func byId(id: String) async throws -> String { id }

                @Get("/users/{name}")
                func byName(name: String) async throws -> String { name }

                static func registerRoutes(into router: RouteRegistry) {
                    router.register(method: .get, path: "/api/users/{id}", auth: AuthRequirement.none, summary: nil) { ctx in
                        let arg_id = try SwiftCoreWeb.bindRouteValue(ctx.request.routeValues["id"], as: String.self, parameterName: "id")
                        return try await Self.init().byId(id: arg_id).toHttpResult()
                    }
                }
            }

            extension UserController: RouteProvider {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Duplicate route: this method and HTTP method combination is already registered on this controller. 'GET /api/users/{name}'.", line: 6, column: 5)
            ],
            macros: ["Controller": ControllerMacro.self]
        )
    }

    func testDisjointConstraintsAreNotDuplicates() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class UserController {
                @Get("/users/{id:int}")
                func byInt(id: Int) async throws -> String { "\\(id)" }

                @Get("/users/{id:uuid}")
                func byUuid(id: UUID) async throws -> String { "\\(id)" }
            }
            """,
            expandedSource: """
            final class UserController {
                @Get("/users/{id:int}")
                func byInt(id: Int) async throws -> String { "\\(id)" }

                @Get("/users/{id:uuid}")
                func byUuid(id: UUID) async throws -> String { "\\(id)" }

                static func registerRoutes(into router: RouteRegistry) {
                    router.register(method: .get, path: "/api/users/{id:int}", auth: AuthRequirement.none, summary: nil) { ctx in
                        let arg_id = try SwiftCoreWeb.bindRouteValue(ctx.request.routeValues["id"], as: Int.self, parameterName: "id")
                        return try await Self.init().byInt(id: arg_id).toHttpResult()
                    }
                    router.register(method: .get, path: "/api/users/{id:uuid}", auth: AuthRequirement.none, summary: nil) { ctx in
                        let arg_id = try SwiftCoreWeb.bindRouteValue(ctx.request.routeValues["id"], as: UUID.self, parameterName: "id")
                        return try await Self.init().byUuid(id: arg_id).toHttpResult()
                    }
                }
            }

            extension UserController: RouteProvider {
            }
            """,
            macros: ["Controller": ControllerMacro.self]
        )
    }

    func testChainedConstraintsKeepPathAndBindDeclaredType() {
        assertMacroExpansion(
            """
            @Controller("/api")
            final class ItemController {
                @Get("/items/{id:long:min(1)}")
                func item(id: Int64) async throws -> String { "\\(id)" }
            }
            """,
            expandedSource: """
            final class ItemController {
                @Get("/items/{id:long:min(1)}")
                func item(id: Int64) async throws -> String { "\\(id)" }

                static func registerRoutes(into router: RouteRegistry) {
                    router.register(method: .get, path: "/api/items/{id:long:min(1)}", auth: AuthRequirement.none, summary: nil) { ctx in
                        let arg_id = try SwiftCoreWeb.bindRouteValue(ctx.request.routeValues["id"], as: Int64.self, parameterName: "id")
                        return try await Self.init().item(id: arg_id).toHttpResult()
                    }
                }
            }

            extension ItemController: RouteProvider {
            }
            """,
            macros: ["Controller": ControllerMacro.self]
        )
    }

    func testMalformedConstraintDiagnoses() {
        assertMacroExpansion(
            """
            final class ItemController {
                @Get("/{id:range(5,1)}")
                func item(id: Int) async throws -> String { "" }
            }
            """,
            expandedSource: """
            final class ItemController {
                func item(id: Int) async throws -> String { "" }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Invalid route template syntax. Unsupported or malformed constraint ':range(5,1)' on placeholder '{id}' (supported: alpha, bool, double, int, length, long, max, maxlength, min, minlength, range, uuid)", line: 2, column: 10)
            ],
            macros: ["Get": RouteMethodMacro.self]
        )
    }

    func testStringConstraintOnIntParameterDiagnoses() {
        assertMacroExpansion(
            """
            final class ItemController {
                @Get("/{code:length(3)}")
                func item(code: Int) async throws -> String { "" }
            }
            """,
            expandedSource: """
            final class ItemController {
                func item(code: Int) async throws -> String { "" }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Route constraint does not match the type of the parameter that binds the placeholder. Constraint ':length(3)' on '{code}' requires String, but the parameter is 'Int'.", line: 3, column: 21)
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
