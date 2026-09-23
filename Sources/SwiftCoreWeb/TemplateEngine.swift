// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOConcurrencyHelpers

/// A lightweight, Vue-safe server-side token-replacement engine (the server-side template engine design).
///
/// Server delimiters are `[[ ]]` (configurable), so Vue's `{{ }}` and
/// directives are never touched. Values are HTML-escaped by default; raw
/// output uses `[[& value]]`. Supports `[[#if x]]…[[/if]]` and
/// `[[#each items]]…[[/each]]` only — no expressions beyond a dotted path
/// lookup, since anything richer belongs in Vue itself. Content inside
/// `v-pre` elements and `<script>` blocks is left untouched.
public enum TemplateEngine {
    /// Delimiters a template's server tokens are wrapped in. The default
    /// `[[ ]]` never collides with Vue's `{{ }}`.
    public struct Delimiters: Sendable {
        public let open: String
        public let close: String
        public init(open: String = "[[", close: String = "]]") {
            self.open = open
            self.close = close
        }
    }

    /// Renders `template` against `model` (a flattened JSON object) using
    /// `delimiters`. `model` is `nil` for a bare `View(name)` with no data.
    static func render(template: String, model: [String: Any], delimiters: Delimiters = Delimiters()) -> String {
        var output = ""
        var scanner = Substring(template)
        renderSegment(&scanner, into: &output, model: model, delimiters: delimiters, stopTags: [])
        return output
    }

    /// Renders one segment, stopping (without consuming) when it encounters
    /// any tag in `stopTags` (used by `#if`/`#each` to find their `[[/…]]`).
    /// Returns the tag name it stopped on, or `nil` if it consumed to the end.
    @discardableResult
    private static func renderSegment(
        _ scanner: inout Substring,
        into output: inout String,
        model: [String: Any],
        delimiters: Delimiters,
        stopTags: Set<String>
    ) -> String? {
        while !scanner.isEmpty {
            // Pass through raw HTML up to the next literal-block or tag.
            if let (blockName, blockBody, rest) = nextRawBlock(scanner) {
                output.append(contentsOf: blockBody)
                scanner = rest
                _ = blockName
                continue
            }

            guard let tagRange = scanner.range(of: delimiters.open) else {
                output.append(contentsOf: scanner)
                scanner = Substring("")
                return nil
            }

            output.append(contentsOf: scanner[scanner.startIndex..<tagRange.lowerBound])
            scanner = scanner[tagRange.upperBound...]

            guard let closeRange = scanner.range(of: delimiters.close) else {
                // Unterminated tag: emit the opener literally and stop.
                output.append(delimiters.open)
                return nil
            }
            let rawTag = scanner[scanner.startIndex..<closeRange.lowerBound].trimmingCharacters(in: .whitespaces)
            scanner = scanner[closeRange.upperBound...]

            if rawTag.hasPrefix("/") {
                let name = String(rawTag.dropFirst())
                if stopTags.contains(name) { return name }
                continue // stray/mismatched closer: ignore
            }

            if rawTag.hasPrefix("#if ") {
                let condition = String(rawTag.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                let isTruthy = truthy(lookup(condition, in: model))
                var branch = ""
                _ = renderSegment(&scanner, into: &branch, model: model, delimiters: delimiters, stopTags: ["if"])
                if isTruthy { output.append(branch) }
                continue
            }

            if rawTag.hasPrefix("#each ") {
                let path = String(rawTag.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                let bodyStart = scanner
                var discarded = ""
                _ = renderSegment(&scanner, into: &discarded, model: model, delimiters: delimiters, stopTags: ["each"])
                let bodyTemplate = String(bodyStart[bodyStart.startIndex..<indexBeforeCloseTag(bodyStart, scanner, delimiters: delimiters)])

                if let items = lookup(path, in: model) as? [[String: Any]] {
                    for item in items {
                        var itemScanner = Substring(bodyTemplate)
                        renderSegment(&itemScanner, into: &output, model: item, delimiters: delimiters, stopTags: [])
                    }
                }
                continue
            }

            if rawTag.hasPrefix("&") {
                let path = String(rawTag.dropFirst()).trimmingCharacters(in: .whitespaces)
                output.append(stringify(lookup(path, in: model)))
                continue
            }

            output.append(escapeHtml(stringify(lookup(rawTag, in: model))))
        }
        return nil
    }

    /// Computes the substring boundary just before the `[[/each]]`/`[[/if]]`
    /// closer, given the scanner position before and after consuming the body.
    private static func indexBeforeCloseTag(_ before: Substring, _ after: Substring, delimiters: Delimiters) -> String.Index {
        // `after` starts right past the matched closing tag; walk back to
        // find where that tag's opener began within `before`.
        let consumedLength = before.utf8.count - after.utf8.count
        let closerApproxLength = delimiters.open.utf8.count + delimiters.close.utf8.count + 6 // "/each" / "/if" + slack
        let bodyLength = max(consumedLength - closerApproxLength, 0)
        return before.index(before.startIndex, offsetBy: min(bodyLength, before.count))
    }

    /// Passes through content inside `<script>…</script>` or a `v-pre`
    /// element verbatim, never scanning it for server tags. Returns `nil`
    /// (falls through to normal tag scanning) when `scanner` does not begin
    /// with such a block at its current position — this only special-cases
    /// the exact start of one, mid-scan text is handled by the normal path.
    private static func nextRawBlock(_ scanner: Substring) -> (name: String, body: Substring, rest: Substring)? {
        for tag in ["<script", "v-pre"] {
            guard scanner.hasPrefix("<") else { continue }
            if scanner.hasPrefix(tag), tag == "<script" {
                guard let closeTagRange = scanner.range(of: "</script>") else { continue }
                let body = scanner[scanner.startIndex..<closeTagRange.upperBound]
                return ("script", body, scanner[closeTagRange.upperBound...])
            }
        }
        return nil
    }

    private static func lookup(_ path: String, in model: [String: Any]) -> Any? {
        var current: Any? = model
        for key in path.split(separator: ".") {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[String(key)]
        }
        return current
    }

    private static func truthy(_ value: Any?) -> Bool {
        switch value {
        case nil: return false
        case let bool as Bool: return bool
        case let string as String: return !string.isEmpty
        case let array as [Any]: return !array.isEmpty
        case let number as NSNumber: return number != 0
        default: return true
        }
    }

    private static func stringify(_ value: Any?) -> String {
        switch value {
        case nil: return ""
        case let string as String: return string
        case let bool as Bool: return bool ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        default: return "\(value!)"
        }
    }

    private static func escapeHtml(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for char in string {
            switch char {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            case "'": result.append("&#39;")
            default: result.append(char)
            }
        }
        return result
    }

    /// Escapes a JSON payload for safe embedding inside an inline
    /// `<script>` tag: `<`, `>`, `&`, U+2028, U+2029.
    static func escapeForInlineScript(_ json: String) -> String {
        json
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

/// Parses and caches compiled templates by resource name, so repeated
/// `View(name)` renders don't re-read disk on every request. Reloaded on
/// change in `.development` (mtime-checked on each lookup, negligible cost
/// next to disk I/O the render already pays).
final class TemplateCache: @unchecked Sendable {
    private struct Entry { let source: String; let modified: Date }
    private var entries: [String: Entry] = [:]
    private let lock = NIOLock()
    let isDevelopment: Bool
    let root: ContentRoot

    init(root: ContentRoot, isDevelopment: Bool) {
        self.root = root
        self.isDevelopment = isDevelopment
    }

    func source(for templateName: String) -> String? {
        guard let rootPath = resolveContentRoot(root),
              let filePath = resolveStaticFilePath(root: rootPath, requestPath: "/" + templateName) else {
            return nil
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: filePath)[.modificationDate] as? Date) ?? nil

        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[templateName], !isDevelopment || cached.modified == modified {
            return cached.source
        }
        guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        entries[templateName] = Entry(source: contents, modified: modified ?? .distantPast)
        return contents
    }
}

extension WebApplication {
    /// Registers the template engine's view root (defaults to the static
    /// files/SPA content root, `.bundle("www")`, when not called). Call once
    /// before returning `View(_:model:)` from a handler.
    @discardableResult
    public func useViews(root: ContentRoot = .bundle("www")) -> Self {
        templateCacheBox.cache = TemplateCache(root: root, isDevelopment: environment == .development)
        return self
    }
}

/// Holds the `WebApplication`-scoped `TemplateCache` so `View.toHttpResult()`
/// can render without every `View` value carrying a reference to the app.
final class TemplateCacheBox: @unchecked Sendable {
    private let lock = NIOLock()
    private var _cache: TemplateCache?
    var cache: TemplateCache? {
        get { lock.lock(); defer { lock.unlock() }; return _cache }
        set { lock.lock(); defer { lock.unlock() }; _cache = newValue }
    }
}

/// The process-wide box `View.toHttpResult()` reads from. One `WebApplication`
/// per process is the supported shape (the core engine/configuration design); this mirrors that assumption
/// rather than threading the app through every handler's return value.
let sharedTemplateCacheBox = TemplateCacheBox()

extension WebApplication {
    var templateCacheBox: TemplateCacheBox { sharedTemplateCacheBox }
}

extension View {
    public func toHttpResult() throws -> HttpResult {
        var headers = HttpHeaders()
        headers["Content-Type"] = "text/html; charset=utf-8"

        guard let cache = sharedTemplateCacheBox.cache, let source = cache.source(for: templateName) else {
            throw HttpError(.internalServerError, "View template '\(templateName)' not found — call app.useViews(root:) and confirm the file exists")
        }

        var model: [String: Any] = [:]
        if let modelData, let decoded = try? JSONSerialization.jsonObject(with: modelData) as? [String: Any] {
            model = decoded
        }
        let rendered = TemplateEngine.render(template: source, model: model)
        return HttpResult(HttpResponse(status: .ok, headers: headers, body: .text(rendered)))
    }
}

/// Serializes `value` into `<script>window.__INITIAL_STATE__=…</script>`
/// (the server-side template engine design), safely escaped so Vue can bootstrap without an extra request.
public func injectState<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw HttpError(.internalServerError, "Failed to encode initial state")
    }
    let escaped = TemplateEngine.escapeForInlineScript(json)
    return "<script>window.__INITIAL_STATE__=\(escaped)</script>"
}
