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
    /// Raw constraint tokens in declaration order (`["int", "min(1)"]`); all must match.
    let constraints: [String]
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
                let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                let name = parts[0]
                let constraints = parts.dropFirst().map { $0.filter { !$0.isWhitespace } }
                guard isValidIdentifierName(name) else {
                    throw RouteTemplateError.invalidSyntax("Invalid placeholder name '\(name)' in route template '\(template)'")
                }
                for constraint in constraints where RouteConstraintSpec(token: constraint) == nil {
                    throw RouteTemplateError.invalidSyntax(
                        "Unsupported or malformed constraint ':\(constraint)' on placeholder '{\(name)}' (supported: \(RouteConstraintSpec.supportedDescription))"
                    )
                }
                parameters.append(RouteTemplateParameter(name: name, constraints: constraints, isOptional: isOptional, isCatchAll: isCatchAll))
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
    /// runtime `CompiledRouteTemplate.shapeKey` so both targets agree on what is a duplicate.
    static func shapeKey(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).map { segment -> String in
            guard segment.hasPrefix("{"), segment.hasSuffix("}") else { return "lit:\(segment)" }
            var body = String(segment.dropFirst().dropLast())
            if body.hasPrefix("*") { return "all" }
            let isOptional = body.hasSuffix("?")
            if isOptional { body.removeLast() }
            let constraints = body.split(separator: ":", omittingEmptySubsequences: false).dropFirst()
                .map { $0.filter { !$0.isWhitespace } }.joined(separator: ":")
            return "\(isOptional ? "opt" : "param"):\(constraints)"
        }.joined(separator: "/")
    }

    private static func isValidIdentifierName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

/// One validated constraint token (`int`, `range(1,10)`).
///
/// Keep the supported set and syntax identical to the runtime's
/// `RouteConstraint` (`Sources/SwiftCoreWeb/RouteTemplateMatcher.swift`),
/// which this target cannot import. A constraint only guides matching; the
/// handler parameter's declared type does the conversion, so each constraint
/// lists the Swift types it can sensibly bind to.
struct RouteConstraintSpec {
    let name: String
    let types: Set<String>

    private static let table: [String: (arguments: ClosedRange<Int>, types: Set<String>)] = [
        "int": (0...0, ["Int"]), "uuid": (0...0, ["UUID"]), "long": (0...0, ["Int64"]),
        "bool": (0...0, ["Bool"]), "double": (0...0, ["Double", "Float"]), "alpha": (0...0, ["String"]),
        "min": (1...1, ["Int", "Int64"]), "max": (1...1, ["Int", "Int64"]), "range": (2...2, ["Int", "Int64"]),
        "length": (1...2, ["String"]), "minlength": (1...1, ["String"]), "maxlength": (1...1, ["String"])
    ]

    static var supportedDescription: String { table.keys.sorted().joined(separator: ", ") }

    /// `nil` when the token is unknown or its arguments are malformed.
    init?(token: String) {
        var name = token
        var arguments: [Int] = []
        if let open = token.firstIndex(of: "("), token.hasSuffix(")") {
            name = String(token[..<open])
            let parsed = token[token.index(after: open)..<token.index(before: token.endIndex)]
                .split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
            guard !parsed.contains(where: { $0 == nil }) else { return nil }
            arguments = parsed.compactMap { $0 }
        }
        guard let entry = Self.table[name], entry.arguments.contains(arguments.count) else { return nil }
        if name == "range" || (name == "length" && arguments.count == 2), arguments[0] > arguments[1] { return nil }
        if name.hasSuffix("length"), arguments.contains(where: { $0 < 0 }) { return nil }
        self.name = name
        self.types = entry.types
    }
}
