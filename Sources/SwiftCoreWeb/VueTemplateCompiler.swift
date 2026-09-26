// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import JavaScriptCore
import NIOConcurrencyHelpers

/// Precompiles a Vue template into a `render` function on the server (the Live Pages design), so the
/// browser never runs `Function("Vue", code)` — required under a strict
/// `default-src 'self'` CSP with no `unsafe-eval` (confirmed against real
/// WebKit/Safari, see `AI-Workspace/Plans/LIVE_PAGES_PLAN.md` step 1).
///
/// Uses the vendored `@vue/compiler-dom` browser IIFE build (same pinned
/// version as `VueRuntime.version`, kept in lockstep by `scripts/update-vue.sh`)
/// evaluated in a `JSContext` (JavaScriptCore, iOS 7+/macOS 10.9+, no new
/// platform requirement). Compiled output is cached per template name and
/// reloaded on change in `.development` (same mtime pattern as `TemplateCache`).
final class VueTemplateCompiler: @unchecked Sendable {
    private struct Entry { let compiled: String; let modified: Date }
    private var entries: [String: Entry] = [:]
    private let lock = NIOLock()
    private var context: JSContext?
    let isDevelopment: Bool

    init(isDevelopment: Bool) {
        self.isDevelopment = isDevelopment
    }

    /// Returns `window.__scwLive["<name>"] = function (Vue) { <render code> };`
    /// for the given template, compiling (or reusing the cached compile) as needed.
    func compile(name: String, template: String, modified: Date) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = entries[name], !isDevelopment || cached.modified == modified {
            return cached.compiled
        }

        let render = try compileRenderFunction(template)
        let wrapped = "(window.__scwLive ||= {})[\(jsStringLiteral(name))] = function (Vue) { \(render) };"
        entries[name] = Entry(compiled: wrapped, modified: modified)
        return wrapped
    }

    /// Lazily creates the `JSContext` and evaluates the vendored compiler IIFE once per process.
    private func loadedContext() throws -> JSContext {
        if let context { return context }

        guard let url = Bundle.module.url(forResource: "compiler-dom.global.prod", withExtension: "js", subdirectory: "vue"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw HttpError(.internalServerError, "compiler-dom.global.prod.js resource missing")
        }
        guard let ctx = JSContext() else {
            throw HttpError(.internalServerError, "JavaScriptCore context could not be created")
        }
        ctx.evaluateScript(source)
        guard ctx.exception == nil, ctx.objectForKeyedSubscript("VueCompilerDOM") != nil else {
            throw HttpError(.internalServerError, "Failed to load @vue/compiler-dom: \(ctx.exception?.toString() ?? "unknown error")")
        }
        context = ctx
        return ctx
    }

    /// Calls `VueCompilerDOM.compile(template, { hoistStatic: true, onError })` in function
    /// mode (the vendored browser build has no `mode: 'module'`/`prefixIdentifiers` support)
    /// and returns the `code` field, or throws with the compiler's own error message/position.
    private func compileRenderFunction(_ template: String) throws -> String {
        let ctx = try loadedContext()
        ctx.exception = nil

        var compileError: String?
        let onError: @convention(block) (JSValue?) -> Void = { error in
            compileError = error?.toString() ?? "unknown compile error"
        }
        ctx.setObject(onError, forKeyedSubscript: "__scwOnCompileError" as NSString)

        let options = "{ hoistStatic: true, onError: __scwOnCompileError }"
        let call = "VueCompilerDOM.compile(\(jsStringLiteral(template)), \(options))"
        guard let result = ctx.evaluateScript(call) else {
            throw HttpError(.internalServerError, "Vue template compile failed: \(compileError ?? ctx.exception?.toString() ?? "unknown error")")
        }
        if let compileError {
            throw HttpError(.internalServerError, "Vue template compile failed: \(compileError)")
        }
        if let exception = ctx.exception {
            throw HttpError(.internalServerError, "Vue template compile failed: \(exception.toString() ?? "unknown error")")
        }
        guard let code = result.objectForKeyedSubscript("code")?.toString() else {
            throw HttpError(.internalServerError, "Vue template compile returned no code")
        }
        return code
    }

    /// A JSON-string literal is always a valid, safely-escaped JS string literal.
    private func jsStringLiteral(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

/// Holds the `WebApplication`-scoped `VueTemplateCompiler`, mirroring `TemplateCacheBox`
/// (one `WebApplication` per process is the supported shape).
final class VueTemplateCompilerBox: @unchecked Sendable {
    private let lock = NIOLock()
    private var _compiler: VueTemplateCompiler?
    var compiler: VueTemplateCompiler? {
        get { lock.lock(); defer { lock.unlock() }; return _compiler }
        set { lock.lock(); defer { lock.unlock() }; _compiler = newValue }
    }
}

let sharedVueTemplateCompilerBox = VueTemplateCompilerBox()
