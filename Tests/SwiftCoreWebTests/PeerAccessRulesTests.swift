// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb

final class PeerAccessRulesTests: XCTestCase {
    func testEverythingIsAllowedUntilARuleSaysOtherwise() {
        let rules = PeerAccessRules()
        XCTAssertTrue(rules.allows(path: "/anything/at/all"))
        XCTAssertTrue(rules.allows(path: "/"))
    }

    func testPrefixMatchesWholeSegmentsOnly() {
        let rules = PeerAccessRules()
        rules.set(prefix: "/admin", allowed: false)
        XCTAssertFalse(rules.allows(path: "/admin"))
        XCTAssertFalse(rules.allows(path: "/admin/users/1"))
        XCTAssertTrue(rules.allows(path: "/administrator"), "a longer name is a different segment")
        XCTAssertTrue(rules.allows(path: "/other/admin"))
    }

    func testMostSpecificRuleWinsAndDefaultApplies() {
        let rules = PeerAccessRules()
        rules.set(prefix: "/api", allowed: true)
        rules.set(prefix: "/api/admin", allowed: false)
        rules.set(prefix: "/api/admin/public", allowed: true)
        rules.setDefault(false)
        XCTAssertTrue(rules.allows(path: "/api/users"))
        XCTAssertFalse(rules.allows(path: "/api/admin/x"))
        XCTAssertTrue(rules.allows(path: "/api/admin/public/x"))
        XCTAssertFalse(rules.allows(path: "/home"), "the default applies where no rule names the path")
    }

    func testPlaceholderSegmentMatchesAnyValueAndLaterRuleReplacesEarlier() {
        let rules = PeerAccessRules()
        rules.set(prefix: "/users/{id}/private", allowed: false)
        XCTAssertFalse(rules.allows(path: "/users/42/private/data"))
        XCTAssertTrue(rules.allows(path: "/users/42/public"))
        rules.set(prefix: "/users/{id}/private", allowed: true)
        XCTAssertTrue(rules.allows(path: "/users/42/private/data"))
    }

    func testRouteGroupRulesCoverNestedGroups() {
        let app = WebApplication.createBuilder().build()
        app.mapGroup("/g").setPeerAccess(allowed: false).mapGroup("/inner").setPeerAccess(allowed: true)
        XCTAssertFalse(app.routeRegistry.peerAccess.allows(path: "/g/x"))
        XCTAssertTrue(app.routeRegistry.peerAccess.allows(path: "/g/inner/x"))
        XCTAssertTrue(app.routeRegistry.peerAccess.allows(path: "/other"))
    }

    func testDotSegmentsCaseAndPercentEncodingCannotSlipPastARule() {
        let rules = PeerAccessRules()
        rules.set(prefix: "/private", allowed: false)
        XCTAssertFalse(rules.allows(path: "/./private/doc.txt"), "static files normalize ./")
        XCTAssertFalse(rules.allows(path: "/x/../private/doc.txt"))
        XCTAssertFalse(rules.allows(path: "/PRIVATE/doc.txt"), "a case-insensitive volume serves it")
        XCTAssertFalse(rules.allows(path: "/%70rivate/doc.txt"), "percent-decoded form is checked too")
        XCTAssertTrue(rules.allows(path: "/public/doc.txt"))
    }

    func testEqualLengthRulesLastOneWinsAndRootRuleCoversEverything() {
        let rules = PeerAccessRules()
        rules.set(prefix: "/users/me", allowed: true)
        rules.set(prefix: "/users/{id}", allowed: false)
        XCTAssertFalse(rules.allows(path: "/users/me"), "same length: the rule set last wins, not the literal")
        rules.set(prefix: "/", allowed: false)
        XCTAssertFalse(rules.allows(path: "/anything"))
    }
}
