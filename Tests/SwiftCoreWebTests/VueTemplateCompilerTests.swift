// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb

final class VueTemplateCompilerTests: XCTestCase {
    func testCompilesValidTemplate() throws {
        let compiler = VueTemplateCompiler(isDevelopment: false)
        let template = """
        <input v-model="form.name" @change="$swift('name')">
        <select v-model="form.country" @change="$swift('country')">
          <option v-for="c in countries" :value="c.value">{{ c.label }}</option>
        </select>
        <p v-if="errors.name">{{ errors.name }}</p>
        """
        let output = try compiler.compile(name: "order", template: template, modified: .distantPast)

        XCTAssertTrue(output.hasPrefix("(window.__scwLive ||= {})[\"order\"] = function (Vue) {"))
        XCTAssertTrue(output.contains("const _Vue = Vue"))
        XCTAssertTrue(output.contains("with (_ctx)"))
    }

    func testInvalidTemplateThrowsWithMessage() {
        let compiler = VueTemplateCompiler(isDevelopment: false)
        // `v-for` without an `item in items` expression — compiler-dom reports this via `onError`.
        let template = "<div v-for=\"item\"></div>"

        XCTAssertThrowsError(try compiler.compile(name: "broken", template: template, modified: .distantPast)) { error in
            guard let httpError = error as? HttpError else {
                return XCTFail("expected HttpError, got \(error)")
            }
            XCTAssertEqual(httpError.status, .internalServerError)
            XCTAssertTrue((httpError.detail ?? "").contains("compiler-32"), "detail: \(httpError.detail ?? "nil")")
        }
    }

    func testCachesCompileAndRecompilesOnMtimeChangeInDevelopment() throws {
        let compiler = VueTemplateCompiler(isDevelopment: true)
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)

        let first = try compiler.compile(name: "counter", template: "<p>{{ a }}</p>", modified: t1)
        let cached = try compiler.compile(name: "counter", template: "<p>{{ b }}</p>", modified: t1)
        XCTAssertEqual(first, cached, "same mtime must reuse the cached compile, ignoring the changed template")

        let recompiled = try compiler.compile(name: "counter", template: "<p>{{ b }}</p>", modified: t2)
        XCTAssertNotEqual(first, recompiled, "a newer mtime in .development must trigger recompilation")
    }

    func testProductionNeverRecompilesOnMtimeChange() throws {
        let compiler = VueTemplateCompiler(isDevelopment: false)
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)

        let first = try compiler.compile(name: "counter", template: "<p>{{ a }}</p>", modified: t1)
        let stillCached = try compiler.compile(name: "counter", template: "<p>{{ b }}</p>", modified: t2)
        XCTAssertEqual(first, stillCached, "outside .development the cache must never invalidate on mtime")
    }
}
