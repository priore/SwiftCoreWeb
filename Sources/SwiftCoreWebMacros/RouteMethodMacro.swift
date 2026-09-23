// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `@Get`/`@Post`/`@Put`/`@Patch`/`@Delete`/`@Head`/`@Options`/`@Route`.
///
/// A peer macro: it cannot add a `RouteProvider` conformance (only
/// `@Controller`'s member/extension macro can), so it generates no code.
/// Its entire job is compile-time validation (the macro compile-time diagnostics design): the route template
/// parses, every placeholder has a matching parameter and vice versa, every
/// parameter type is bindable, and the return type is supported.
///
/// A `PeerMacro` is handed a `declaration` detached from its parent tree
/// (swift-syntax expands each attribute against an isolated copy), so this
/// macro cannot itself see whether that declaration sits inside a
/// `@Controller` type. `ControllerMacro.markerOutsideController(in:)` covers
/// that check instead, where the real member list is available.
///
/// `ControllerMacro` re-parses the same attribute arguments to generate
/// `registerRoutes(into:)` — this macro's job ends at diagnostics.
public struct RouteMethodMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            context.diagnose(RouteDiagnostic.markerOnNonFunction.at(declaration))
            return []
        }

        guard let arguments = RouteMarkerArguments(node: node, context: context) else {
            return []
        }

        let templateParameters: [RouteTemplateParameter]
        do {
            templateParameters = try RouteTemplateParser.parse(arguments.path)
        } catch RouteTemplateError.invalidSyntax(let detail) {
            context.diagnose(RouteDiagnostic.invalidRouteTemplate.at(arguments.pathExpr, detail: detail))
            return []
        }

        let parameters = bindableParameters(from: function.signature)
        guard resolveParameterBindings(
            parameters: parameters,
            routeParameters: templateParameters,
            httpMethod: arguments.method,
            node: function.signature,
            context: context
        ) != nil else {
            return []
        }

        if let returnClause = function.signature.returnClause, !isPlausibleReturnType(returnClause.type) {
            context.diagnose(RouteDiagnostic.unsupportedReturnType.at(returnClause.type))
        }

        return []
    }

    /// Rejects return type syntax that can never satisfy the return-type conversion rules (function
    /// types, tuples other than `()`). Any named/optional type is otherwise
    /// trusted to be `Encodable`/`HttpResultConvertible` — see `describeType`.
    private static func isPlausibleReturnType(_ type: TypeSyntax) -> Bool {
        if type.is(FunctionTypeSyntax.self) { return false }
        if let tuple = type.as(TupleTypeSyntax.self) { return tuple.elements.isEmpty }
        return true
    }
}

/// The common `(_ path: String, auth: AuthRequirement, summary: String?)`
/// argument shape shared by every route marker, plus the HTTP method it
/// implies (fixed for `@Get`/etc., taken from the first argument for `@Route`).
struct RouteMarkerArguments {
    let method: String
    let path: String
    let pathExpr: ExprSyntax

    init?(node: AttributeSyntax, context: some MacroExpansionContext) {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        let macroName = node.attributeName.trimmedDescription

        var positional = Array(arguments.filter { $0.label == nil })
        if macroName == "Route" {
            // @Route(_ method: HttpMethod, _ path: String, ...)
            guard positional.count >= 2 else { return nil }
            let methodExpr = positional[positional.startIndex]
            method = RouteMarkerArguments.methodName(from: methodExpr.expression)
            positional.removeFirst()
        } else {
            method = macroName.uppercased()
        }

        guard let pathArgument = positional.first, let stringLiteral = pathArgument.expression.as(StringLiteralExprSyntax.self) else {
            return nil
        }
        pathExpr = pathArgument.expression
        path = stringLiteral.segments.compactMap { segment -> String? in
            if case .stringSegment(let literalSegment) = segment {
                return literalSegment.content.text
            }
            return nil
        }.joined()
    }

    /// Reads the `HttpMethod` case name out of `.get`/`HttpMethod.get`-style
    /// syntax for `@Route`'s explicit method argument.
    private static func methodName(from expr: ExprSyntax) -> String {
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName.text.uppercased()
        }
        return expr.trimmedDescription.uppercased()
    }
}
