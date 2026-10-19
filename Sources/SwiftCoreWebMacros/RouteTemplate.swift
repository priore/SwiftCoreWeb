// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// One `{placeholder}` segment parsed out of a route template string, used
/// only at macro-expansion time to validate parameter binding (the parameter-binding rules) and
/// emit diagnostics (the macro compile-time diagnostics design). The runtime template matcher (Part 3) re-parses
/// the same syntax independently — this type never leaves the macro target.
struct RouteTemplateParameter {
    let name: String
    let constraint: String?
    let isOptional: Bool
    let isCatchAll: Bool
}

enum RouteTemplateError: Error {
    case invalidSyntax(String)
}

/// Parses a route template (`/users/{id:int}/{page?}`, `/files/{*path}`)
/// into its literal structure and placeholders. Recognizes the same syntax
/// documented in the Minimal API closure routing design: typed constraints (`{id:int}`, `{id:uuid}`), optional
/// segments (`{page?}`), and a trailing catch-all (`{*path}`).
enum RouteTemplateParser {
    static func parse(_ template: String) throws -> [RouteTemplateParameter] {
        var parameters: [RouteTemplateParameter] = []
        var seenCatchAll = false
        var index = template.startIndex
        while index < template.endIndex {
            let char = template[index]
            if char == "{" {
                guard let close = template[index...].firstIndex(of: "}") else {
                    throw RouteTemplateError.invalidSyntax("Unterminated '{' in route template '\(template)'")
                }
                if seenCatchAll {
                    throw RouteTemplateError.invalidSyntax("Catch-all '{*...}' must be the last segment in '\(template)'")
                }
                var body = String(template[template.index(after: index)..<close])
                if body.isEmpty {
                    throw RouteTemplateError.invalidSyntax("Empty '{}' placeholder in route template '\(template)'")
                }
                var isCatchAll = false
                if body.hasPrefix("*") {
                    isCatchAll = true
                    seenCatchAll = true
                    body.removeFirst()
                }
                var isOptional = false
                if body.hasSuffix("?") {
                    isOptional = true
                    body.removeLast()
                }
                let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
                let name = parts[0]
                let constraint = parts.count > 1 ? parts[1] : nil
                guard isValidIdentifierName(name) else {
                    throw RouteTemplateError.invalidSyntax("Invalid placeholder name '\(name)' in route template '\(template)'")
                }
                if let constraint, !Self.supportedConstraints.contains(constraint) {
                    throw RouteTemplateError.invalidSyntax(
                        "Unsupported constraint ':\(constraint)' on placeholder '{\(name)}' (supported: \(Self.supportedConstraints.sorted().joined(separator: ", ")))"
                    )
                }
                parameters.append(RouteTemplateParameter(name: name, constraint: constraint, isOptional: isOptional, isCatchAll: isCatchAll))
                index = template.index(after: close)
            } else {
                if char == "}" {
                    throw RouteTemplateError.invalidSyntax("Unmatched '}' in route template '\(template)'")
                }
                index = template.index(after: index)
            }
        }
        let names = parameters.map(\.name)
        if Set(names).count != names.count {
            throw RouteTemplateError.invalidSyntax("Duplicate placeholder name in route template '\(template)'")
        }
        return parameters
    }

    /// Placeholder-name-independent shape of a route path, mirroring the
    /// runtime router's `shapeKey` so both targets agree on what is a duplicate.
    static func shapeKey(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).map { segment -> String in
            guard segment.hasPrefix("{"), segment.hasSuffix("}") else { return "lit:\(segment)" }
            var body = String(segment.dropFirst().dropLast())
            if body.hasPrefix("*") { return "all" }
            let isOptional = body.hasSuffix("?")
            if isOptional { body.removeLast() }
            let constraint = body.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            return "\(isOptional ? "opt" : "param"):\(constraint)"
        }.joined(separator: "/")
    }

    private static let supportedConstraints: Set<String> = ["int", "uuid"]

    /// Swift parameter types each constraint can bind to; a constraint is
    /// only for matching, the handler's declared type does the conversion.
    static let constraintTypes: [String: Set<String>] = ["int": ["Int"], "uuid": ["UUID"]]

    private static func isValidIdentifierName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
