// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb

final class RouteConstraintTests: XCTestCase {
    /// Matches `value` against `/x/{v:<constraint>}`; `nil` means no match.
    private func matches(_ constraint: String, _ value: String) throws -> Bool {
        let template = try CompiledRouteTemplate("/x/{v:\(constraint)}")
        return template.match(pathComponents: ["x", Substring(value)]) != nil
    }

    func testBuiltInTypeConstraints() throws {
        XCTAssertTrue(try matches("int", "42"))
        XCTAssertFalse(try matches("int", "4.2"))
        XCTAssertTrue(try matches("uuid", "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        XCTAssertFalse(try matches("uuid", "nope"))
        XCTAssertTrue(try matches("long", "9223372036854775807"))
        XCTAssertFalse(try matches("long", "9223372036854775808"))
        XCTAssertTrue(try matches("bool", "true"))
        XCTAssertFalse(try matches("bool", "True"))
        XCTAssertTrue(try matches("double", "3.14"))
        XCTAssertFalse(try matches("double", "abc"))
    }

    func testAlphaIsAsciiLettersOnlyAndNonEmpty() throws {
        XCTAssertTrue(try matches("alpha", "AbcXyz"))
        XCTAssertFalse(try matches("alpha", "abc1"))
        XCTAssertFalse(try matches("alpha", "é"))
        XCTAssertFalse(try matches("alpha", "a-b"))
        XCTAssertFalse(try matches("alpha", "@"))
        XCTAssertFalse(try matches("alpha", "["))
    }

    func testNumericBounds() throws {
        XCTAssertTrue(try matches("min(5)", "5"))
        XCTAssertFalse(try matches("min(5)", "4"))
        XCTAssertFalse(try matches("min(5)", "x"))
        XCTAssertTrue(try matches("max(5)", "-100"))
        XCTAssertFalse(try matches("max(5)", "6"))
        XCTAssertTrue(try matches("range(1,10)", "10"))
        XCTAssertTrue(try matches("range(1, 10)", "1"))
        XCTAssertFalse(try matches("range(1,10)", "11"))
    }

    func testLengthBounds() throws {
        XCTAssertTrue(try matches("length(3)", "abc"))
        XCTAssertFalse(try matches("length(3)", "abcd"))
        XCTAssertTrue(try matches("length(2,4)", "abcd"))
        XCTAssertFalse(try matches("length(2,4)", "a"))
        XCTAssertTrue(try matches("minlength(2)", "abcdefgh"))
        XCTAssertFalse(try matches("minlength(2)", "a"))
        XCTAssertTrue(try matches("maxlength(2)", "ab"))
        XCTAssertFalse(try matches("maxlength(2)", "abc"))
    }

    func testChainedConstraintsMustAllMatch() throws {
        XCTAssertTrue(try matches("int:min(1)", "7"))
        XCTAssertFalse(try matches("int:min(1)", "0"))
        XCTAssertFalse(try matches("int:min(1)", "x"))
        XCTAssertTrue(try matches("int:min(1):max(9)", "9"))
        XCTAssertFalse(try matches("int:min(1):max(9)", "10"))
    }

    func testMalformedConstraintsThrowAtRegistration() {
        for bad in ["min(x)", "min", "min()", "min(1,2)", "range(5,1)", "range(1)", "length(-1)",
                    "length(4,2)", "int(3)", "regex(a)", "nope", "", "int:"] {
            XCTAssertThrowsError(try CompiledRouteTemplate("/x/{v:\(bad)}"), "'\(bad)' should be rejected")
        }
    }

    func testOptionalAndConstrainedPlaceholder() throws {
        let template = try CompiledRouteTemplate("/x/{page:int:min(1)?}")
        XCTAssertNotNil(template.match(pathComponents: ["x"]))
        XCTAssertNotNil(template.match(pathComponents: ["x", "3"]))
        XCTAssertNil(template.match(pathComponents: ["x", "0"]))
    }
}
