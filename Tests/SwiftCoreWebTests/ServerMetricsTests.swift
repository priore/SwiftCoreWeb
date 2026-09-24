// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb
import SwiftCoreWebTesting

final class ServerMetricsTests: XCTestCase {
    private func makeApp() -> WebApplication {
        let app = WebApplication.createBuilder().build()
        app.mapGet("/api/ok") { _ in "ok" }
        app.mapGet("/api/boom") { _ in HttpResult(HttpResponse(status: .internalServerError)) }
        return app
    }

    /// Drives N requests through `TestHost` (which shares `RequestDispatcher.dispatch`
    /// with the live server engine) and checks `ServerMetrics` counts and status
    /// classes match — the Step 1 verification from the dashboard plan.
    func testRequestCountsAndStatusClassesMatch() async throws {
        let app = makeApp()
        let host = try await TestHost(app)

        for _ in 0..<5 {
            _ = try await host.get("/api/ok")
        }
        for _ in 0..<2 {
            _ = try await host.get("/api/boom")
        }
        _ = try await host.get("/api/does-not-exist")

        let snapshot = app.metrics.snapshot()
        XCTAssertEqual(snapshot.totalRequests, 8)
        XCTAssertEqual(snapshot.statusClassCounts[2], 5)
        XCTAssertEqual(snapshot.statusClassCounts[5], 2)
        XCTAssertEqual(snapshot.statusClassCounts[4], 1)
        XCTAssertEqual(snapshot.recentRequests.count, 8)
    }
}
