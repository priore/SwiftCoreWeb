// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb

final class WebSocketAuthTests: XCTestCase {
    private func makeDispatcher() throws -> RequestDispatcher {
        let app = WebApplication.createBuilder().build()
        app.useAuthentication(.custom("key") { request in
            request.headers["X-Key"] == "ok" ? ClaimsPrincipal(claims: [], roles: ["admin"], scheme: "key") : nil
        })
        app.useAuthorization()
        return try app.makeDispatcher()
    }

    private func request(key: String?) -> HttpRequest {
        var headers = HttpHeaders()
        if let key { headers["X-Key"] = key }
        return HttpRequest(method: .get, path: "/live", headers: headers)
    }

    func testUnauthenticatedUpgradeIsRejectedWith401() async throws {
        let denied = try await makeDispatcher().authorizeUpgrade(request(key: nil), auth: .authenticated)
        XCTAssertEqual(denied?.status.rawValue, 401)
    }

    func testAuthenticatedUpgradeProceeds() async throws {
        let denied = try await makeDispatcher().authorizeUpgrade(request(key: "ok"), auth: .authenticated)
        XCTAssertNil(denied)
    }

    func testMissingRoleIsRejectedWith403() async throws {
        let denied = try await makeDispatcher().authorizeUpgrade(request(key: "ok"), auth: .roles(["root"]))
        XCTAssertEqual(denied?.status.rawValue, 403)
    }
}
