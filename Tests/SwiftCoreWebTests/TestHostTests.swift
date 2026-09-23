// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb
import SwiftCoreWebTesting

private struct GreetingUser: Codable, Equatable {
    let id: Int
    let name: String
}

final class TestHostTests: XCTestCase {
    private func makeApp() -> WebApplication {
        let app = WebApplication.createBuilder().build()
        app.mapGet("/api/users/{id:int}") { ctx in
            GreetingUser(id: try bindRouteValue(ctx.request.routeValues["id"], as: Int.self, parameterName: "id"), name: "Ada")
        }
        app.mapPost("/api/users") { ctx in
            let user = try ctx.request.decode(GreetingUser.self)
            return Results.created(location: "/api/users/\(user.id)", user)
        }
        app.mapGet("/api/ping") { _ in "pong" }
        app.mapGet("/api/secret", auth: .authenticated) { _ in "top secret" }
        return app
    }

    func testGetRouteRunsThroughFullPipelineAndDecodesJson() async throws {
        let host = try await TestHost(makeApp())
        let response = try await host.get("/api/users/1")
        XCTAssertEqual(response.status, 200)
        let user = try response.decode(GreetingUser.self)
        XCTAssertEqual(user, GreetingUser(id: 1, name: "Ada"))
    }

    func testPostRouteWithJsonBody() async throws {
        let host = try await TestHost(makeApp())
        let response = try await host.post("/api/users", json: GreetingUser(id: 42, name: "Grace"))
        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(response.headers["Location"], "/api/users/42")
    }

    func testPlainTextRoute() async throws {
        let host = try await TestHost(makeApp())
        let response = try await host.get("/api/ping")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.bodyString, "pong")
    }

    func testHeadMirrorsGetHeadersWithoutBody() async throws {
        let host = try await TestHost(makeApp())
        let response = try await host.head("/api/ping")
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.body.isEmpty)
    }

    func testUnknownRouteReturnsNotFoundProblem() async throws {
        let host = try await TestHost(makeApp())
        let response = try await host.get("/api/does-not-exist")
        XCTAssertEqual(response.status, 404)
    }

    func testMethodNotAllowedIncludesAllowHeader() async throws {
        let host = try await TestHost(makeApp())
        let response = try await host.send(.delete, "/api/ping")
        XCTAssertEqual(response.status, 405)
        XCTAssertNotNil(response.headers["Allow"])
    }

    func testAuthenticatedRouteWithoutCredentialIsUnauthorized() async throws {
        let app = makeApp()
        app.useAuthentication()
        app.useAuthorization()
        let host = try await TestHost(app)
        let response = try await host.get("/api/secret")
        XCTAssertEqual(response.status, 401)
    }
}
