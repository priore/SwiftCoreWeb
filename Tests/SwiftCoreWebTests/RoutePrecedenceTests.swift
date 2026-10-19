// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb
import SwiftCoreWebTesting

@Controller("/x")
private struct ItemController {
    @Get("/{id:int}")
    func byId(id: Int) -> String { "controller:\(id)" }

    @Get("/me")
    func me() -> String { "controller:me" }
}

/// End to end: controller and closure routes share one precedence model,
/// and controller constraints take part in matching.
final class RoutePrecedenceTests: XCTestCase {
    private func makeHost(controllerFirst: Bool) async throws -> TestHost {
        let app = WebApplication.createBuilder().build()
        if controllerFirst { _ = app.mapControllers(ItemController.self) }
        app.mapGet("/x/{slug}") { ctx in "closure:\(ctx.request.routeValues["slug"] ?? "")" }
        if !controllerFirst { _ = app.mapControllers(ItemController.self) }
        return try await TestHost(app)
    }

    func testControllerConstraintFallsThroughToClosureInEitherOrder() async throws {
        for controllerFirst in [true, false] {
            let host = try await makeHost(controllerFirst: controllerFirst)
            let numeric = try await host.get("/x/42")
            XCTAssertEqual(numeric.bodyString, "controller:42", "controllerFirst: \(controllerFirst)")
            let slug = try await host.get("/x/abc")
            XCTAssertEqual(slug.status, 200)
            XCTAssertEqual(slug.bodyString, "closure:abc", "controllerFirst: \(controllerFirst)")
            let literal = try await host.get("/x/me")
            XCTAssertEqual(literal.bodyString, "controller:me", "controllerFirst: \(controllerFirst)")
        }
    }

    func testControllerConstraintMismatchIsNotFoundNotBadRequest() async throws {
        let app = WebApplication.createBuilder().build()
        _ = app.mapControllers(ItemController.self)
        let response = try await TestHost(app).get("/x/abc")
        XCTAssertEqual(response.status, 404)
    }
}
