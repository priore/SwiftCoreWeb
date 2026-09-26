// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb
import SwiftCoreWebTesting

final class SessionTests: XCTestCase {
    private func makeApp(idleTimeout: TimeInterval = 1200) -> WebApplication {
        let app = WebApplication.createBuilder().build()
        app.useSession(idleTimeout: idleTimeout)
        app.mapGet("/read") { ctx in ctx.session.get(String.self, "name") ?? "none" }
        app.mapGet("/write") { ctx -> String in
            ctx.session.set("Ada", "name")
            return "ok"
        }
        return app
    }

    private func sidCookie(_ response: TestResponse) -> String? {
        response.headers.values(for: "Set-Cookie").first { $0.hasPrefix("__scw_sid=") }
            .map { String($0.dropFirst("__scw_sid=".count).prefix { $0 != ";" }) }
    }

    func testNoCookieWithoutSet() async throws {
        let host = try await TestHost(makeApp())
        let response = try await host.get("/read")
        XCTAssertEqual(response.bodyString, "none")
        XCTAssertNil(sidCookie(response))
    }

    func testSetIsReadableOnNextRequest() async throws {
        let host = try await TestHost(makeApp())
        let writeResponse = try await host.get("/write")
        guard let sid = sidCookie(writeResponse) else { return XCTFail("expected __scw_sid cookie after set") }

        let readResponse = try await host.get("/read", headers: [("Cookie", "__scw_sid=\(sid)")])
        XCTAssertEqual(readResponse.bodyString, "Ada")
    }

    func testUnknownIncomingSessionIdIsNotAdopted() async throws {
        let host = try await TestHost(makeApp())
        let response = try await host.get("/read", headers: [("Cookie", "__scw_sid=not-a-real-session")])
        XCTAssertEqual(response.bodyString, "none")
        XCTAssertNil(sidCookie(response), "an unrecognized id must never be echoed back as a valid cookie")
    }

    func testExpiredSessionIsNotAdopted() async throws {
        let host = try await TestHost(makeApp(idleTimeout: 0))
        let writeResponse = try await host.get("/write")
        guard let sid = sidCookie(writeResponse) else { return XCTFail("expected __scw_sid cookie after set") }

        let readResponse = try await host.get("/read", headers: [("Cookie", "__scw_sid=\(sid)")])
        XCTAssertEqual(readResponse.bodyString, "none", "idleTimeout: 0 must expire the session immediately")
    }
}
