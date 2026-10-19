// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb

final class RouterTests: XCTestCase {
    private func makeRouter(_ templates: [String], method: HttpMethod = .get) -> Router {
        let router = Router()
        for template in templates {
            router.register(method: method, path: template, auth: .none, summary: nil) { _ in voidHttpResult() }
        }
        router.freeze()
        return router
    }

    /// The raw template of the route that wins for `path`, or `nil`.
    private func winner(_ router: Router, _ path: String, method: HttpMethod = .get) -> String? {
        if case .matched(let route, _) = router.match(method: method, path: path) { return route.template.raw }
        return nil
    }

    /// Asserts `expected` wins for `path` with `templates` registered in both orders.
    private func assertWinner(
        _ expected: String, for path: String, among templates: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for order in [templates, templates.reversed()] {
            XCTAssertEqual(winner(makeRouter(order), path), expected, "order: \(order)", file: file, line: line)
        }
    }

    func testLiteralBeatsParameter() {
        assertWinner("/users/me", for: "/users/me", among: ["/users/{id}", "/users/me"])
        assertWinner("/users/{id}", for: "/users/7", among: ["/users/{id}", "/users/me"])
    }

    func testConstrainedParameterBeatsFreeParameter() {
        assertWinner("/users/{id:int}", for: "/users/42", among: ["/users/{name}", "/users/{id:int}"])
        assertWinner("/users/{name}", for: "/users/abc", among: ["/users/{name}", "/users/{id:int}"])
        assertWinner("/n/{v:int:min(1)}", for: "/n/5", among: ["/n/{v}", "/n/{v:int:min(1)}"])
    }

    func testOptionalBeatsCatchAll() {
        assertWinner("/a/{rest?}", for: "/a/x", among: ["/a/{rest?}", "/a/{*rest}"])
    }

    func testShorterRouteBeatsOptionalTail() {
        assertWinner("/a", for: "/a", among: ["/a/{page?}", "/a"])
        assertWinner("/a/{page?}", for: "/a/2", among: ["/a/{page?}", "/a"])
    }

    func testMoreLiteralBeatsCatchAll() {
        assertWinner("/files/list", for: "/files/list", among: ["/files/{*path}", "/files/list"])
        assertWinner("/files/{*path}", for: "/files/a/b", among: ["/files/{*path}", "/files/list"])
    }

    func testMethodsAreResolvedIndependently() {
        let router = Router()
        router.register(method: .get, path: "/u/{id}", auth: .none, summary: nil) { _ in voidHttpResult() }
        router.register(method: .post, path: "/u/me", auth: .none, summary: nil) { _ in voidHttpResult() }
        router.freeze()
        XCTAssertEqual(winner(router, "/u/me", method: .get), "/u/{id}")
        XCTAssertEqual(winner(router, "/u/me", method: .post), "/u/me")
    }

    func testMethodNotAllowedAndHeadFallbackUnchanged() {
        let router = makeRouter(["/u/{id}"])
        XCTAssertEqual(winner(router, "/u/1", method: .head), "/u/{id}")
        guard case .methodNotAllowed(let allowed) = router.match(method: .delete, path: "/u/1") else {
            return XCTFail("expected 405")
        }
        XCTAssertEqual(allowed, [.get, .head, .options])
        guard case .notFound = router.match(method: .get, path: "/nope") else { return XCTFail("expected 404") }
    }
}
