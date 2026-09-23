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
/// `{name}`, `{name:int}`, `{name:uuid}`, `{name?}`, `{*name}` — to match
/// requests at runtime.
enum RouteSegment: Sendable, Equatable {
    case literal(String)
    case parameter(name: String, constraint: RouteConstraint?, isOptional: Bool)
    case catchAll(name: String)
}

enum RouteConstraint: Sendable, Equatable {
    case int
    case uuid

    func matches(_ value: String) -> Bool {
        switch self {
        case .int: return Int(value) != nil
        case .uuid: return UUID(uuidString: value) != nil
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

    /// Segment count ignoring a trailing optional or catch-all, used to
    /// route registration-order tie-breaking (more literal segments wins).
    let requiredSegmentCount: Int

    init(_ template: String) throws {
        self.raw = template
        self.segments = try Self.parse(template)
        self.requiredSegmentCount = segments.reduce(into: 0) { count, segment in
            switch segment {
            case .literal: count += 1
            case .parameter(_, _, let isOptional): count += isOptional ? 0 : 1
            case .catchAll: break
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
            case .parameter(let name, let constraint, let isOptional):
                guard pathIndex < pathComponents.endIndex else {
                    if isOptional { continue }
                    return nil
                }
                let component = String(pathComponents[pathIndex])
                if let constraint, !constraint.matches(component) {
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

    private static let supportedConstraints: [String: RouteConstraint] = ["int": .int, "uuid": .uuid]

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
                let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
                let name = parts[0]
                guard isValidIdentifierName(name) else {
                    throw RouteTemplateSyntaxError(message: "Invalid placeholder name '\(name)' in route template '\(template)'")
                }
                var constraint: RouteConstraint?
                if parts.count > 1 {
                    guard let resolved = supportedConstraints[parts[1]] else {
                        throw RouteTemplateSyntaxError(message: "Unsupported constraint ':\(parts[1])' on placeholder '{\(name)}' in '\(template)'")
                    }
                    constraint = resolved
                }
                if isOptional {
                    seenOptional = true
                } else if seenOptional {
                    throw RouteTemplateSyntaxError(message: "Required placeholder '{\(name)}' cannot follow an optional placeholder in '\(template)'")
                }
                segments.append(.parameter(name: name, constraint: constraint, isOptional: isOptional))
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
