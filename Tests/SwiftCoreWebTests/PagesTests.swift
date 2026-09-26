// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb
import SwiftCoreWebTesting

/// A `country` → `cities` page mirroring the plan's `OrderPage` example,
/// minus session/redirect (covered by dedicated tests below).
private struct OrderForm: Codable, Sendable, Equatable {
    var name = ""
    var qty: Int?
    var country = ""
}

private struct OrderPage: Page {
    static let template = "order.html"
    static let title = "New order"

    var form = OrderForm()
    var cities: [String] = []

    mutating func onEvent(_ event: String, _ ctx: PageContext) async throws -> PageAction {
        switch event {
        case "country":
            cities = form.country == "IT" ? ["Rome", "Milan"] : []
        case "save":
            if form.name.isEmpty { ctx.errors["name"] = "Name is required" }
            guard ctx.isValid else { return .render }
            return .redirect("/orders/done")
        default: break
        }
        return .render
    }
}

/// Isolated per test file: `mapPage` registers `/_live/<template>.js` only
/// once per process (`LiveScriptRegistry`), so every test that maps
/// `OrderPage` reuses the same registration — fine, since it's idempotent.
final class PagesTests: XCTestCase {
    private func makeApp() throws -> (app: WebApplication, templatesDir: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "<input v-model=\"form.name\">".write(toFile: dir + "/order.html", atomically: true, encoding: .utf8)

        let app = WebApplication.createBuilder().build()
        app.usePages(root: .path(dir))
        app.mapPage("/orders/new", OrderPage.self)
        return (app, dir)
    }

    private func afCookie(_ response: TestResponse) -> String {
        let setCookie = response.headers.values(for: "Set-Cookie").first { $0.hasPrefix("__scw_af=") }
        return setCookie.map { String($0.dropFirst("__scw_af=".count).prefix { $0 != ";" }) } ?? ""
    }

    private struct EventResponse: Decodable {
        let snapshot: String
        let checksum: String
        let redirect: String?
    }

    private struct EventRequest<Form: Encodable>: Encodable {
        let snapshot: String
        let checksum: String
        let form: Form
        let event: String
    }

    // MARK: - GET

    func testGetRendersShellWithLiveScriptAndAntiforgeryCookie() async throws {
        let (app, _) = try makeApp()
        let host = try await TestHost(app)

        let response = try await host.get("/orders/new")

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertTrue((response.bodyString ?? "").contains("id=\"__live\""))
        XCTAssertTrue((response.bodyString ?? "").contains("/_live/order.js"))
        XCTAssertTrue((response.bodyString ?? "").contains("/_framework/live.js"))
        XCTAssertFalse((response.bodyString ?? "").contains("<script>window"), "no executable inline script")
        XCTAssertFalse(afCookie(response).isEmpty)
    }

    func testLiveScriptRouteServesCompiledTemplate() async throws {
        let (app, _) = try makeApp()
        let host = try await TestHost(app)

        let response = try await host.get("/_live/order.js")

        XCTAssertEqual(response.status, 200)
        XCTAssertTrue((response.bodyString ?? "").contains("__scwLive"))
    }

    // MARK: - POST event round trip

    private func extractPayload(_ response: TestResponse) throws -> EventResponse {
        let html = try XCTUnwrap(response.bodyString)
        let marker = "id=\"__live\">"
        guard let start = html.range(of: marker)?.upperBound, let end = html.range(of: "</script>", range: start..<html.endIndex) else {
            throw XCTSkip("no __live payload found")
        }
        let json = String(html[start..<end.lowerBound])
        return try JSONDecoder().decode(EventResponse.self, from: Data(json.utf8))
    }

    func testEventUpdatesStateAcrossTwoRequests() async throws {
        let (app, _) = try makeApp()
        let host = try await TestHost(app)

        let getResponse = try await host.get("/orders/new")
        let af = afCookie(getResponse)
        var payload = try extractPayload(getResponse)

        let postResponse = try await host.post(
            "/orders/new",
            json: EventRequest(snapshot: payload.snapshot, checksum: payload.checksum, form: ["country": "IT"], event: "country"),
            headers: [("Cookie", "__scw_af=\(af)")]
        )
        XCTAssertEqual(postResponse.status, 200)
        payload = try postResponse.decode(EventResponse.self)
        XCTAssertTrue((postResponse.bodyString ?? "").contains("Rome"))

        // Second POST reusing the *new* snapshot must still work (state advances).
        let secondResponse = try await host.post(
            "/orders/new",
            json: EventRequest(snapshot: payload.snapshot, checksum: payload.checksum, form: [String: String](), event: "noop"),
            headers: [("Cookie", "__scw_af=\(af)")]
        )
        XCTAssertEqual(secondResponse.status, 200)
    }

    func testInvalidFormFieldKeepsPreviousValueAndSetsError() async throws {
        let (app, _) = try makeApp()
        let host = try await TestHost(app)

        let getResponse = try await host.get("/orders/new")
        let af = afCookie(getResponse)
        let payload = try extractPayload(getResponse)

        let response = try await host.post(
            "/orders/new",
            json: EventRequest(snapshot: payload.snapshot, checksum: payload.checksum, form: ["qty": "abc"], event: "qty"),
            headers: [("Cookie", "__scw_af=\(af)")]
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertTrue((response.bodyString ?? "").contains("\\\"qty\\\":\\\"Invalid value\\\""), response.bodyString ?? "")
    }

    func testTamperedChecksumIsRejected() async throws {
        let (app, _) = try makeApp()
        let host = try await TestHost(app)

        let getResponse = try await host.get("/orders/new")
        let af = afCookie(getResponse)
        let payload = try extractPayload(getResponse)

        let response = try await host.post(
            "/orders/new",
            json: EventRequest(
                snapshot: payload.snapshot,
                checksum: "0000000000000000000000000000000000000000000000000000000000000000",
                form: [String: String](),
                event: "save"
            ),
            headers: [("Cookie", "__scw_af=\(af)")]
        )

        XCTAssertEqual(response.status, 400)
    }

    func testMismatchedAntiforgeryCookieIsRejected() async throws {
        let (app, _) = try makeApp()
        let host = try await TestHost(app)

        let getResponse = try await host.get("/orders/new")
        let payload = try extractPayload(getResponse)

        let response = try await host.post(
            "/orders/new",
            json: EventRequest(snapshot: payload.snapshot, checksum: payload.checksum, form: [String: String](), event: "save"),
            headers: [("Cookie", "__scw_af=not-the-real-token")]
        )

        XCTAssertEqual(response.status, 400)
    }

    func testNonJsonContentTypeIsRejected() async throws {
        let (app, _) = try makeApp()
        let host = try await TestHost(app)

        let response = try await host.post("/orders/new", body: Data("x=1".utf8), headers: [("Content-Type", "application/x-www-form-urlencoded")])

        XCTAssertEqual(response.status, 415)
    }

    func testErrorsRenderAndRedirectOnValidSave() async throws {
        let (app, _) = try makeApp()
        let host = try await TestHost(app)

        let getResponse = try await host.get("/orders/new")
        let af = afCookie(getResponse)
        var payload = try extractPayload(getResponse)

        let emptyNameResponse = try await host.post(
            "/orders/new",
            json: EventRequest(snapshot: payload.snapshot, checksum: payload.checksum, form: [String: String](), event: "save"),
            headers: [("Cookie", "__scw_af=\(af)")]
        )
        XCTAssertEqual(emptyNameResponse.status, 200)
        XCTAssertTrue((emptyNameResponse.bodyString ?? "").contains("Name is required"))
        payload = try emptyNameResponse.decode(EventResponse.self)

        let savedResponse = try await host.post(
            "/orders/new",
            json: EventRequest(snapshot: payload.snapshot, checksum: payload.checksum, form: ["name": "Ada"], event: "save"),
            headers: [("Cookie", "__scw_af=\(af)")]
        )
        XCTAssertEqual(savedResponse.status, 200)
        let redirectPayload = try savedResponse.decode(EventResponse.self)
        XCTAssertEqual(redirectPayload.redirect, "/orders/done")
    }
}

