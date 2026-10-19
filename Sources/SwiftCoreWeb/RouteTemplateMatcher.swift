// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// One parsed segment of a route template.
///
/// Runtime counterpart of `SwiftCoreWebMacros.RouteTemplateParameter` (which
/// exists only to drive compile-time diagnostics and never leaves the macro
/// target). This type parses the same syntax — literal segments,
/// `{name}`, `{name:int}`, `{name:int:min(1)}`, `{name?}`, `{*name}` — to
/// match requests at runtime.
enum RouteSegment: Sendable, Equatable {
    case literal(String)
    case parameter(name: String, constraints: [RouteConstraint], isOptional: Bool)
    case catchAll(name: String)
}

/// A route placeholder constraint (`{id:int}`, `{n:range(1,10)}`). Chained
/// constraints (`{id:int:min(1)}`) must all match.
///
/// Keep the supported set and syntax identical to the macro target's
/// `RouteTemplateParser` (`Sources/SwiftCoreWebMacros/RouteTemplate.swift`),
/// which cannot import this module.
enum RouteConstraint: Sendable, Equatable {
    case int, uuid, long, bool, double, alpha
    case min(Int), max(Int), range(Int, Int)
    /// Inclusive character-count bounds; covers `length`, `minlength`, `maxlength`.
    case length(Int, Int)

    func matches(_ value: String) -> Bool {
        switch self {
        case .int: return Int(value) != nil
        case .uuid: return UUID(uuidString: value) != nil
        case .long: return Int64(value) != nil
        case .bool: return Bool(value) != nil
        case .double: return Double(value) != nil
        case .alpha: return !value.isEmpty && value.utf8.allSatisfy { ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7A }
        case .min(let bound): return Int(value).map { $0 >= bound } ?? false
        case .max(let bound): return Int(value).map { $0 <= bound } ?? false
        case .range(let low, let high): return Int(value).map { $0 >= low && $0 <= high } ?? false
        case .length(let low, let high): return (low...high).contains(value.count)
        }
    }

    /// Parses one constraint token such as `int` or `range(1,10)`.
    static func parse(_ rawToken: String, placeholder: String, template: String) throws -> RouteConstraint {
        let token = rawToken.filter { !$0.isWhitespace } // the macro target ignores whitespace too
        func fail(_ reason: String) -> RouteTemplateSyntaxError {
            RouteTemplateSyntaxError(message: "\(reason) ':\(token)' on placeholder '{\(placeholder)}' in '\(template)'")
        }
        var name = token
        var arguments: [Int]?
        if let open = token.firstIndex(of: "("), token.hasSuffix(")") {
            name = String(token[..<open])
            let parsed = token[token.index(after: open)..<token.index(before: token.endIndex)]
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !parsed.contains(where: { $0 == nil }) else { throw fail("Non-integer argument in constraint") }
            arguments = parsed.compactMap { $0 }
        }
        switch (name, arguments?.count) {
        case ("int", nil): return .int
        case ("uuid", nil): return .uuid
        case ("long", nil): return .long
        case ("bool", nil): return .bool
        case ("double", nil): return .double
        case ("alpha", nil): return .alpha
        case ("min", 1?): return .min(arguments![0])
        case ("max", 1?): return .max(arguments![0])
        case ("range", 2?):
            guard arguments![0] <= arguments![1] else { throw fail("Empty range in constraint") }
            return .range(arguments![0], arguments![1])
        case ("length", 1?), ("minlength", 1?), ("maxlength", 1?), ("length", 2?):
            let values = arguments!
            guard values.allSatisfy({ $0 >= 0 }), values.count == 1 || values[0] <= values[1] else {
                throw fail("Invalid length bounds in constraint")
            }
            switch name {
            case "minlength": return .length(values[0], .max)
            case "maxlength": return .length(0, values[0])
            default: return .length(values[0], values.last!)
            }
        default: throw fail("Unsupported constraint")
        }
    }
}

struct RouteTemplateSyntaxError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Parses and matches route templates (`/users/{id:int}/{page?}`,
/// `/files/{*path}`) against request paths, binding placeholder values.
struct CompiledRouteTemplate: Sendable {
    let raw: String
    let segments: [RouteSegment]

    /// Per-segment specificity rank, lower is more specific: literal 0,
    /// constrained parameter 1, parameter 2, optional parameter 3, catch-all 4.
    /// Two templates that match the same path are aligned by position, so
    /// comparing ranks lexicographically picks the more specific one
    /// regardless of registration order (same order as ASP.NET Core).
    let precedence: [Int]

    /// Placeholder-name-independent shape (`lit:users/param:int`): two routes
    /// for the same method with equal shapes are ambiguous. Keep identical to
    /// the macro target's `RouteTemplateParser.shapeKey`.
    let shapeKey: String

    init(_ template: String) throws {
        self.raw = template
        self.segments = try Self.parse(template)
        self.shapeKey = Self.shapeKey(of: template)
        self.precedence = segments.map { segment in
            switch segment {
            case .literal: 0
            case .parameter(_, let constraints, let isOptional): isOptional ? 3 : (constraints.isEmpty ? 2 : 1)
            case .catchAll: 4
            }
        }
    }

    /// Attempts to match `path` (already split on `/`, with empty
    /// components removed), returning bound route values on success.
    func match(pathComponents: [Substring]) -> [String: String]? {
        var values: [String: String] = [:]
        var pathIndex = pathComponents.startIndex
        for (segmentIndex, segment) in segments.enumerated() {
            switch segment {
            case .literal(let text):
                guard pathIndex < pathComponents.endIndex, pathComponents[pathIndex] == text[...] else {
                    return nil
                }
                pathIndex = pathComponents.index(after: pathIndex)
            case .parameter(let name, let constraints, let isOptional):
                guard pathIndex < pathComponents.endIndex else {
                    if isOptional { continue }
                    return nil
                }
                let component = String(pathComponents[pathIndex])
                if !constraints.allSatisfy({ $0.matches(component) }) {
                    return nil
                }
                values[name] = component
                pathIndex = pathComponents.index(after: pathIndex)
            case .catchAll(let name):
                precondition(segmentIndex == segments.count - 1, "catch-all must be the last segment")
                let remaining = pathComponents[pathIndex...]
                guard !remaining.isEmpty else { return nil }
                values[name] = remaining.joined(separator: "/")
                pathIndex = pathComponents.endIndex
            }
        }
        return pathIndex == pathComponents.endIndex ? values : nil
    }

    private static func shapeKey(of template: String) -> String {
        template.split(separator: "/", omittingEmptySubsequences: true).map { component -> String in
            guard component.hasPrefix("{"), component.hasSuffix("}") else { return "lit:\(component)" }
            var body = String(component.dropFirst().dropLast())
            if body.hasPrefix("*") { return "all" }
            let isOptional = body.hasSuffix("?")
            if isOptional { body.removeLast() }
            let constraints = body.split(separator: ":", omittingEmptySubsequences: false).dropFirst()
                .map { $0.filter { !$0.isWhitespace } }.joined(separator: ":")
            return "\(isOptional ? "opt" : "param"):\(constraints)"
        }.joined(separator: "/")
    }

    private static func parse(_ template: String) throws -> [RouteSegment] {
        var segments: [RouteSegment] = []
        var seenCatchAll = false
        var seenOptional = false
        let components = template.split(separator: "/", omittingEmptySubsequences: true)
        for component in components {
            if component.hasPrefix("{"), component.hasSuffix("}") {
                if seenCatchAll {
                    throw RouteTemplateSyntaxError(message: "Catch-all '{*...}' must be the last segment in '\(template)'")
                }
                var body = String(component.dropFirst().dropLast())
                if body.isEmpty {
                    throw RouteTemplateSyntaxError(message: "Empty '{}' placeholder in route template '\(template)'")
                }
                if body.hasPrefix("*") {
                    body.removeFirst()
                    guard isValidIdentifierName(body) else {
                        throw RouteTemplateSyntaxError(message: "Invalid placeholder name '\(body)' in route template '\(template)'")
                    }
                    segments.append(.catchAll(name: body))
                    seenCatchAll = true
                    continue
                }
                var isOptional = false
                if body.hasSuffix("?") {
                    isOptional = true
                    body.removeLast()
                }
                let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                let name = parts[0]
                guard isValidIdentifierName(name) else {
                    throw RouteTemplateSyntaxError(message: "Invalid placeholder name '\(name)' in route template '\(template)'")
                }
                let constraints = try parts.dropFirst().map {
                    try RouteConstraint.parse($0, placeholder: name, template: template)
                }
                if isOptional {
                    seenOptional = true
                } else if seenOptional {
                    throw RouteTemplateSyntaxError(message: "Required placeholder '{\(name)}' cannot follow an optional placeholder in '\(template)'")
                }
                segments.append(.parameter(name: name, constraints: constraints, isOptional: isOptional))
            } else {
                if component.contains("{") || component.contains("}") {
                    throw RouteTemplateSyntaxError(message: "Malformed placeholder in segment '\(component)' of route template '\(template)'")
                }
                segments.append(.literal(String(component)))
            }
        }
        return segments
    }

    private static func isValidIdentifierName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

/// Splits a request path into non-empty components for matching.
func splitPathComponents(_ path: String) -> [Substring] {
    path.split(separator: "/", omittingEmptySubsequences: true)
}
