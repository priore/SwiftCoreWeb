// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb

final class CookiesTests: XCTestCase {
    func testParsesMultipleCookies() {
        var headers = HttpHeaders()
        headers["Cookie"] = "a=1; b=2;  c=3"
        let request = HttpRequest(method: .get, path: "/", headers: headers)

        XCTAssertEqual(request.cookies, ["a": "1", "b": "2", "c": "3"])
    }

    func testNoCookieHeaderIsEmpty() {
        let request = HttpRequest(method: .get, path: "/")
        XCTAssertTrue(request.cookies.isEmpty)
    }

    func testMalformedPairIsSkipped() {
        var headers = HttpHeaders()
        headers["Cookie"] = "a=1; noequals; b=2"
        let request = HttpRequest(method: .get, path: "/", headers: headers)

        XCTAssertEqual(request.cookies, ["a": "1", "b": "2"])
    }

    func testSetCookieDefaults() {
        var response = HttpResponse()
        response.setCookie("sid", "abc")

        XCTAssertEqual(response.headers["Set-Cookie"], "sid=abc; Path=/; SameSite=Lax; HttpOnly")
    }

    func testSetCookieSecureAndMaxAge() {
        var response = HttpResponse()
        response.setCookie("sid", "abc", secure: true, maxAge: 0)

        XCTAssertEqual(response.headers["Set-Cookie"], "sid=abc; Path=/; SameSite=Lax; HttpOnly; Secure; Max-Age=0")
    }

    func testSetCookieAppendsRatherThanReplaces() {
        var response = HttpResponse()
        response.setCookie("sid", "abc")
        response.setCookie("af", "xyz")

        XCTAssertEqual(response.headers.values(for: "Set-Cookie"), [
            "sid=abc; Path=/; SameSite=Lax; HttpOnly",
            "af=xyz; Path=/; SameSite=Lax; HttpOnly"
        ])
    }

    func testContentRootPathResolvesAsGiven() {
        XCTAssertEqual(resolveContentRoot(.path("/tmp/foo")), "/tmp/foo")
    }
}
